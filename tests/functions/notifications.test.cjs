// Notifications: who is told what, and by whom. Every one of them is written by the server inside
// the transaction of the event it announces, so these checks are also a check that the event
// happened at all - and that nothing is addressed to a person the event has nothing to do with.
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
const FN = (name) => `http://127.0.0.1:5001/demo-et/europe-west3/${name}`;

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

async function call(name, token, data) {
  const r = await fetch(FN(name), {
    method: "POST",
    headers: { "content-type": "application/json", authorization: "Bearer " + token },
    body: JSON.stringify({ data }),
  });
  return r.json();
}

const fileOf = (partnerId, orderId, name, kind) => ({
  kind, name,
  url: "http://127.0.0.1:9199/v0/b/demo-et.appspot.com/o/" + encodeURIComponent(`orders/${partnerId}/${orderId}/${name}`) + "?alt=media&token=t",
});

(async () => {
  const b = db.batch();
  b.set(db.doc("partners/nt_farm"), {
    uid: "nt_farm", displayName: "КХ Вестник", status: "verified", totalDeals: 0,
    storefront: { cutting: [], delivery: [{ id: "d1", city: "Астана", price: 5000 }], pickup: true },
  });
  b.set(db.doc("partners/nt_farm2"), { uid: "nt_farm2", displayName: "КХ Второе", status: "pending_review" });
  b.set(db.doc("partners/nt_farm2/documents/nt_doc1"), {
    kind: "ses", label: "СЭС", status: "pending", partnerId: "nt_farm2", fileUrl: "https://example.invalid/ses.pdf",
  });
  b.set(db.doc("animals/nt_a1"), { partnerId: "nt_farm", breed: "Казахская белоголовая", type: "cattle" });
  const lot = {
    partnerId: "nt_farm", name: "Туша №7", status: "open", bookedShares: 0, totalShares: 2,
    pricePerKg: 3500, totalWeight: 120, pricePerShare: 210000, animalIds: ["nt_a1"],
  };
  ["NT1", "NT2"].forEach((id) => b.set(db.doc("lots/" + id), lot));
  b.set(db.doc("staff/nt_admin"), { uid: "nt_admin", role: "admin" });
  await b.commit();

  const farmer = await idTokenFor("nt_farm", "+15550009401");
  const buyer = await idTokenFor("nt_buyer", "+15550009402");
  const admin = await idTokenFor("nt_admin", "+15550009403", { role: "admin" });

  const checks = [];
  const act = (token, orderId, action, extra = {}) => call("updateOrderStatus", token, { orderId, action, ...extra });

  /** Everything addressed to this person, newest first. */
  const notes = async (uid) => {
    const snap = await db.collection("notifications").where("uid", "==", uid).get();
    return snap.docs.map((d) => d.data()).sort((a, b) => b.createdAt.toMillis() - a.createdAt.toMillis());
  };
  const latest = async (uid) => (await notes(uid))[0] || {};
  const check = async (label, fn) => {
    let pass = false;
    let info = "";
    try { pass = await fn(); } catch (e) { info = String(e); }
    if (!pass && !info) info = JSON.stringify(await latest(label.includes("хозяйств") ? "nt_farm" : "nt_buyer"));
    checks.push([pass, label, pass ? "" : info]);
  };

  let key = 0;
  const place = async (lotId) => {
    const res = await call("createOrder", buyer, {
      lotId, format: "half", deliveryId: "d1", deliveryAddress: "Астана, ул. Тестовая 1",
      contactPhone: "+77000000000", idempotencyKey: "notif-key-" + (++key),
    });
    if (!res.result) throw new Error("order not placed: " + JSON.stringify(res));
    return res.result.orderId;
  };

  // ---- the order road ------------------------------------------------------------------------
  const A = await place("NT1"); // 3 500 × 60 кг + 5 000 = 215 000
  await check("новый заказ приходит хозяйству, а не покупателю", async () => {
    const farm = await latest("nt_farm");
    return farm.kind === "order_new" && farm.orderId === A && farm.read === false
      && farm.link === `/cabinet/order?id=${A}` && farm.body.includes("215 000 ₸")
      && (await notes("nt_buyer")).length === 0;
  });

  await act(farmer, A, "accept");
  await check("покупатель узнаёт, что заказ принят", async () => {
    const n = await latest("nt_buyer");
    return n.kind === "order_accepted" && n.link === `/order?id=${A}` && n.orderId === A;
  });

  await act(farmer, A, "identify", { files: [fileOf("nt_farm", A, "animal.mp4", "video")] });
  await check("шаг 1 виден покупателю", async () => (await latest("nt_buyer")).title === "Фермер показал животное");

  await act(farmer, A, "meat_ready", {
    files: [fileOf("nt_farm", A, "meat.jpg", "photo")],
    scalePhoto: fileOf("nt_farm", A, "scale.jpg", "photo"),
    weightKg: 62.4,
  });
  await check("в уведомлении о взвешивании есть вес и доплата", async () => {
    const n = await latest("nt_buyer");
    return n.title === "Мясо готово" && n.body.includes("62,4 кг") && n.body.includes("Доплата 8 400 ₸");
  });

  await act(farmer, A, "ship");
  await act(farmer, A, "handover");
  await check("при передаче названо время автозавершения", async () => {
    const n = await latest("nt_buyer");
    return n.kind === "order_handover" && /до \d\d:\d\d/.test(n.body);
  });

  await act(buyer, A, "complete");
  await check("подтверждение покупателя слышит хозяйство", async () => {
    const n = await latest("nt_farm");
    return n.kind === "order_completed" && n.title === "Покупатель подтвердил получение";
  });

  // ---- a dispute and its decision ------------------------------------------------------------
  const B = await place("NT2");
  await act(farmer, B, "accept");
  await act(farmer, B, "identify", { files: [fileOf("nt_farm", B, "a.jpg", "photo")] });
  await act(farmer, B, "meat_ready", { files: [fileOf("nt_farm", B, "m.jpg", "photo")], weightKg: 60 });
  await act(farmer, B, "ship");
  await act(buyer, B, "dispute", { description: "Запах, куски не те" });
  await check("о споре узнаёт хозяйство", async () => {
    const n = await latest("nt_farm");
    return n.kind === "order_disputed" && n.orderId === B;
  });

  const disputeId = (await db.doc("orders/" + B).get()).data().disputeId;
  await call("reviewDispute", admin, {
    disputeId, action: "resolve", outcome: "partner", note: "Проверили съёмку — мясо соответствует",
  });
  await check("решение по спору получают обе стороны, каждая своими словами", async () => {
    const forBuyer = await latest("nt_buyer");
    const forFarm = await latest("nt_farm");
    return forBuyer.kind === "dispute_resolved" && forBuyer.body.includes("Проверили съёмку")
      && forFarm.kind === "dispute_resolved" && forFarm.body.includes("выплата открыта");
  });

  // ---- decisions about the farm itself --------------------------------------------------------
  await call("reviewPartner", admin, { partnerId: "nt_farm2", decision: "reject", note: "Справки просрочены" });
  await check("отказ в проверке приходит хозяйству с причиной", async () => {
    const n = await latest("nt_farm2");
    return n.kind === "farm_review" && n.title === "Хозяйство не допущено к продажам" && n.body.includes("Справки просрочены");
  });

  await call("reviewDocument", admin, { partnerId: "nt_farm2", docId: "nt_doc1", decision: "approve" });
  await check("решение по документу приходит его владельцу", async () => {
    const n = await latest("nt_farm2");
    return n.kind === "document_review" && n.title === "Документ принят" && n.link === "/cabinet/storefront";
  });

  // ---- nothing reaches anyone else -------------------------------------------------------------
  await check("посторонний не получает ничего", async () => (await notes("nt_stranger")).length === 0);
  await check("каждое уведомление непрочитано и адресовано одному человеку", async () => {
    const all = await db.collection("notifications").get();
    return all.docs.every((d) => typeof d.data().uid === "string" && d.data().read === false && d.data().title.length > 0);
  });

  for (const [pass, label, info] of checks) console.log(`  ${pass ? "ok  " : "FAIL"}  ${label}${pass ? "" : "  " + info}`);
  const failed = checks.filter((c) => !c[0]).length;
  console.log(`\nnotifications: ${checks.length - failed}/${checks.length} passed`);
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
