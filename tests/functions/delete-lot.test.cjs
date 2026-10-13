// deleteLot: удалять лоты из служебной панели может только модератор, лот с бронями — только
// вторым, подтверждённым запросом, и каждое удаление оставляет запись в журнале.
//
// Runs against the local emulators under a demo- project id, so it can never touch production:
//   cd tests/functions && npm test
const path = require("path");
const fnModules = path.join(__dirname, "../../functions/node_modules");
const { initializeApp } = require(path.join(fnModules, "firebase-admin/lib/app/index.js"));
const { getFirestore } = require(path.join(fnModules, "firebase-admin/lib/firestore/index.js"));
const { getAuth } = require(path.join(fnModules, "firebase-admin/lib/auth/index.js"));

if (!process.env.FIRESTORE_EMULATOR_HOST || !process.env.FIREBASE_AUTH_EMULATOR_HOST) {
  console.error("refusing to run outside the emulator");
  process.exit(2);
}

initializeApp({ projectId: "demo-et" });
const db = getFirestore();
const auth = getAuth();
const FN = "http://127.0.0.1:5001/demo-et/europe-west3/deleteLot";

async function idTokenFor(uid, phone, claims = {}) {
  await auth.createUser({ uid, phoneNumber: phone }).catch(() => {});
  const custom = await auth.createCustomToken(uid, claims);
  const r = await fetch(`http://${process.env.FIREBASE_AUTH_EMULATOR_HOST}/identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key=fake`, {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ token: custom, returnSecureToken: true }),
  });
  const j = await r.json();
  if (!j.idToken) throw new Error("no token: " + JSON.stringify(j));
  return j.idToken;
}

async function remove(token, data) {
  const r = await fetch(FN, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: "Bearer " + token },
    body: JSON.stringify({ data }),
  });
  // Эмулятор на незагруженную функцию отвечает обычным текстом, а не JSON. Разбирать его как
  // JSON — падать с невнятной ошибкой разбора вместо внятной «функции ещё нет».
  const body = await r.text();
  try {
    return JSON.parse(body);
  } catch {
    return { raw: body };
  }
}

// emulators:exec запускает тест, как только поднялся хаб, — функции к этому моменту могут ещё
// регистрироваться. Без ожидания первый же вызов получает «function does not exist».
async function waitForFunction() {
  for (let i = 0; i < 40; i++) {
    const res = await remove("", {});
    if (!String(res.raw || "").includes("does not exist")) return;
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error("deleteLot так и не поднялась в эмуляторе");
}

(async () => {
  await waitForFunction();

  const lot = (booked) => ({
    partnerId: "dl_farm", name: "Казахская белоголовая, торпақ", status: booked ? "fully_booked" : "open",
    totalShares: 2, bookedShares: booked, totalWeight: 200, pricePerKg: 3500, regionCode: "ASTANA",
  });

  const b = db.batch();
  b.set(db.doc("staff/dl_admin"), { uid: "dl_admin", role: "admin" });
  b.set(db.doc("staff/dl_support"), { uid: "dl_support", role: "support" });
  b.set(db.doc("lots/dl_free"), lot(0));
  b.set(db.doc("lots/dl_booked"), lot(2));
  b.set(db.doc("lots/dl_guard"), lot(0));
  // Шаги доставки под лотом: они должны уйти вместе с ним, иначе останутся висеть сиротами.
  b.set(db.doc("lots/dl_free/deliveries/step_1"), { lotId: "dl_free", order: 1, status: "pending" });
  b.set(db.doc("lots/dl_free/deliveries/step_2"), { lotId: "dl_free", order: 2, status: "pending" });
  await b.commit();

  const admin = await idTokenFor("dl_admin", "+15550009001", { role: "admin" });
  const support = await idTokenFor("dl_support", "+15550009002", { role: "support" });
  const farmer = await idTokenFor("dl_farm", "+15550009003");
  const ghost = await idTokenFor("dl_ghost", "+15550009004", { role: "admin" }); // claim, no staff record

  const checks = [];
  const expectError = async (label, token, data, status) => {
    const res = await remove(token, data);
    const ok = !!res.error && res.error.status === status;
    checks.push([ok, label, ok ? "" : JSON.stringify(res)]);
  };
  const expectOk = async (label, token, data, verify) => {
    const res = await remove(token, data);
    let ok = !!res.result;
    if (ok && verify) ok = await verify(res.result);
    checks.push([ok, label, ok ? "" : JSON.stringify(res)]);
  };
  const gone = async (id) => !(await db.doc("lots/" + id).get()).exists;

  await expectError("хозяин лота — не сотрудник, ему сюда нельзя", farmer,
    { lotId: "dl_guard" }, "PERMISSION_DENIED");
  await expectError("поддержка не модерирует каталог", support,
    { lotId: "dl_guard" }, "PERMISSION_DENIED");
  await expectError("claim без записи в staff не проходит", ghost,
    { lotId: "dl_guard" }, "PERMISSION_DENIED");
  await expectError("несуществующий лот", admin, { lotId: "нет-такого" }, "NOT_FOUND");
  await expectError("лот без идентификатора", admin, {}, "INVALID_ARGUMENT");

  await expectError("занятый лот без подтверждения не удаляется", admin,
    { lotId: "dl_booked" }, "FAILED_PRECONDITION");

  await expectOk("модератор удаляет свободный лот вместе с шагами доставки", admin,
    { lotId: "dl_free" }, async (res) => {
      const steps = await db.collection("lots/dl_free/deliveries").get();
      return await gone("dl_free") && steps.empty && res.deletedSteps === 2;
    });

  await expectOk("занятый лот удаляется подтверждённым запросом", admin,
    { lotId: "dl_booked", force: true }, async (res) => await gone("dl_booked") && res.bookedShares === 2);

  // Журнал: по записи на каждое удавшееся удаление, и ни одной на отказ.
  const rows = (await db.collection("adminActions").where("targetType", "==", "lot").get())
    .docs.map((d) => d.data());
  const forced = rows.find((r) => r.targetId === "dl_booked");
  checks.push([rows.length === 2, "в журнале ровно два удаления", `их ${rows.length}`]);
  checks.push([rows.every((r) => r.action === "lot.delete" && r.actorUid === "dl_admin"),
    "каждая запись называет действие и автора", ""]);
  checks.push([forced?.before?.bookedShares === 2 && !!forced?.note,
    "удаление занятого лота записано вместе с числом броней", JSON.stringify(forced?.before)]);
  checks.push([(await db.doc("lots/dl_guard").get()).exists,
    "лот, который только пытались удалить, остался на месте", ""]);

  let failed = 0;
  for (const [ok, label, detail] of checks) {
    if (!ok) failed++;
    console.log(`${ok ? "  ok  " : "FAIL  "}${label}${detail ? " — " + detail : ""}`);
  }
  console.log(`\ndeleteLot: ${checks.length - failed} из ${checks.length}`);
  process.exit(failed ? 1 : 0);
})();
