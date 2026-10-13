// Удаление аккаунта: что уходит, что остаётся и когда удалить нельзя.
//
// Требование Google Play — удалять аккаунт можно из самого приложения. Но заказ это сделка двух
// сторон, а отзыв — часть чужого рейтинга, поэтому у кнопки есть правила, и они проверяются
// здесь: незакрытая сделка держит аккаунт, закрытая остаётся без личных данных, отзыв остаётся
// без имени.
//
// Runs against the local emulators under a demo- project id:
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

async function idTokenFor(uid, phone) {
  await auth.createUser({ uid, phoneNumber: phone }).catch(() => {});
  const custom = await auth.createCustomToken(uid);
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

(async () => {
  const checks = [];
  const check = async (label, fn) => {
    let pass = false;
    let info = "";
    try {
      pass = await fn();
    } catch (e) {
      info = String(e && e.message ? e.message : e);
    }
    checks.push([pass, label, info]);
  };

  // ---- a buyer in the middle of a deal ---------------------------------------------------------
  const busy = await idTokenFor("da_busy", "+15550101010");
  await db.doc("clients/da_busy").set({ uid: "da_busy", displayName: "Занятый", phone: "+15550101010" });
  await db.doc("orders/da_o_active").set({
    buyerUid: "da_busy", partnerId: "da_farm", status: "accepted", amount: 100000, createdAt: new Date(),
  });

  const refused = await call("deleteMyAccount", busy, { role: "buyer" });
  await check("незакрытый заказ держит аккаунт", () =>
    refused.error?.status === "FAILED_PRECONDITION" && refused.error.message.includes("незакрытый заказ"));
  await check("после отказа аккаунт и профиль на месте", async () => {
    const profile = await db.doc("clients/da_busy").get();
    const user = await auth.getUser("da_busy").catch(() => null);
    return profile.exists && user !== null;
  });

  // ---- a buyer in a gathering that is still filling ----------------------------------------------
  const gathering = await idTokenFor("da_group", "+15550202020");
  await db.doc("clients/da_group").set({ uid: "da_group", displayName: "Собирающий" });
  await db.doc("groupBuys/da_g1").set({
    lotId: "da_lot", partnerId: "da_farm", size: 3, status: "open",
    memberUids: ["da_group"], members: [{ uid: "da_group", name: "Собирающий", amount: 1000 }],
    createdAt: new Date(),
  });
  const refusedGroup = await call("deleteMyAccount", gathering, { role: "buyer" });
  await check("идущий сбор держит аккаунт", () =>
    refusedGroup.error?.status === "FAILED_PRECONDITION" && refusedGroup.error.message.includes("сбор"));

  // ---- a buyer whose deals are closed --------------------------------------------------------------
  const done = await idTokenFor("da_done", "+15550303030");
  await db.doc("clients/da_done").set({ uid: "da_done", displayName: "Закончивший", phone: "+15550303030" });
  await db.doc("clients/da_done/cart/item1").set({ lotId: "da_lot", format: "half" });
  await db.doc("clients/da_done/devices/da_token_xxxxxxxxxxxxxxxxxxxxxxxx").set({ token: "da_token_xxxxxxxxxxxxxxxxxxxxxxxx", platform: "android" });
  await db.doc("notifications/da_n1").set({ uid: "da_done", title: "Заказ принят", body: "", read: false, createdAt: new Date() });
  await db.doc("orders/da_o_done").set({
    buyerUid: "da_done", partnerId: "da_farm", status: "completed", amount: 232500,
    contactPhone: "+15550303030", buyerPhone: "+15550303030", deliveryAddress: "Астана, ул. Тестовая 7",
    createdAt: new Date(),
  });
  await db.doc("reviews/da_r1").set({
    partnerId: "da_farm", buyerUid: "da_done", buyerName: "Закончивший", rating: 5,
    text: "Мясо отличное", status: "published", createdAt: new Date(),
  });
  // a joint purchase someone else placed, where this person was only a participant
  await db.doc("orders/da_o_shared").set({
    buyerUid: "da_other", partnerId: "da_farm", status: "completed", amount: 232500,
    contactPhone: "+15559999999", deliveryAddress: "Астана, пр. Чужой 1",
    memberUids: ["da_other", "da_done"],
    group: { id: "da_g0", size: 2, members: [
      { uid: "da_other", name: "Организатор", amount: 116250 },
      { uid: "da_done", name: "Закончивший", amount: 116250 },
    ] },
    createdAt: new Date(),
  });

  const deleted = await call("deleteMyAccount", done, { role: "buyer" });
  await check("закрытые сделки — аккаунт удаляется", () => deleted.result?.deleted === true);

  await check("профиль, корзина, телефоны и уведомления стёрты", async () => {
    const profile = await db.doc("clients/da_done").get();
    const cart = await db.collection("clients/da_done/cart").get();
    const devices = await db.collection("clients/da_done/devices").get();
    const notes = await db.collection("notifications").where("uid", "==", "da_done").get();
    return !profile.exists && cart.empty && devices.empty && notes.empty;
  });

  await check("вход по этому аккаунту больше не существует", async () => {
    const user = await auth.getUser("da_done").catch(() => null);
    return user === null;
  });

  await check("закрытый заказ остался, но без телефона и адреса", async () => {
    const order = (await db.doc("orders/da_o_done").get()).data();
    return order && order.status === "completed" && order.amount === 232500
      && order.contactPhone === null && order.deliveryAddress === null && order.buyerDeletedAt;
  });

  await check("отзыв остался без имени — рейтинг хозяйства сложился из него", async () => {
    const review = (await db.doc("reviews/da_r1").get()).data();
    return review && review.text === "Мясо отличное" && review.buyerName === "Покупатель" && review.buyerUid === null;
  });

  await check("в чужой совместной покупке стёрто только имя участника", async () => {
    const order = (await db.doc("orders/da_o_shared").get()).data();
    const members = order.group.members;
    return order.contactPhone === "+15559999999"
      && order.deliveryAddress === "Астана, пр. Чужой 1"
      && members[0].name === "Организатор"
      && members[1].name === "Участник";
  });

  // ---- a farm with a booked carcass ---------------------------------------------------------------
  const farm = await idTokenFor("da_farm_busy", "+15550404040");
  await db.doc("partners/da_farm_busy").set({ uid: "da_farm_busy", displayName: "КХ Занятое", status: "verified" });
  await db.doc("lots/da_lot_booked").set({ partnerId: "da_farm_busy", name: "Туша", bookedShares: 1, totalShares: 2, status: "open" });
  const refusedFarm = await call("deleteMyAccount", farm, { role: "partner" });
  await check("бронь на туше держит аккаунт хозяйства", () =>
    refusedFarm.error?.status === "FAILED_PRECONDITION" && refusedFarm.error.message.includes("брони"));

  // ---- a farm with nothing outstanding -------------------------------------------------------------
  const quiet = await idTokenFor("da_farm_quiet", "+15550505050");
  await db.doc("partners/da_farm_quiet").set({ uid: "da_farm_quiet", displayName: "КХ Тихое", status: "verified" });
  await db.doc("partners/da_farm_quiet/private/identity").set({ iin: "123456789012" });
  await db.doc("lots/da_lot_free").set({ partnerId: "da_farm_quiet", name: "Туша", bookedShares: 0, totalShares: 2, status: "draft" });
  await db.doc("animals/da_a1").set({ partnerId: "da_farm_quiet", breed: "Ангус" });
  await db.doc("orders/da_o_farm_done").set({
    buyerUid: "da_someone", partnerId: "da_farm_quiet", status: "completed", amount: 77000, createdAt: new Date(),
  });

  const farmDeleted = await call("deleteMyAccount", quiet, { role: "partner" });
  await check("хозяйство без открытых дел удаляется", () => farmDeleted.result?.deleted === true);
  await check("профиль, ИИН, скот и несданные лоты хозяйства стёрты", async () => {
    const profile = await db.doc("partners/da_farm_quiet").get();
    const iin = await db.doc("partners/da_farm_quiet/private/identity").get();
    const lot = await db.doc("lots/da_lot_free").get();
    const animal = await db.doc("animals/da_a1").get();
    return !profile.exists && !iin.exists && !lot.exists && !animal.exists;
  });
  await check("закрытый заказ хозяйства остался — это запись о деньгах", async () => {
    const order = (await db.doc("orders/da_o_farm_done").get()).data();
    return order && order.amount === 77000 && order.partnerDeletedAt;
  });

  for (const [pass, label, info] of checks) console.log(`  ${pass ? "ok  " : "FAIL"}  ${label}${pass ? "" : "  " + info}`);
  const failed = checks.filter((c) => !c[0]).length;
  console.log(`\ndelete account: ${checks.length - failed}/${checks.length} passed`);
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
