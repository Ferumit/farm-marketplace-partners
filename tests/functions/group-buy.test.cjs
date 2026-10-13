// Joint purchase: gathering 2-5 people around one carcass, the even split of its cost, the order
// that appears only when the last place is filled - and what happens when the carcass is sold
// while the group is still filling (nothing is held, so the group fails and says so).
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

(async () => {
  const b = db.batch();
  b.set(db.doc("partners/gb_farm"), {
    uid: "gb_farm", displayName: "КХ Складчина", status: "verified", totalDeals: 0,
    storefront: { cutting: [], delivery: [{ id: "d1", city: "Алматы", price: 6000 }], pickup: true },
  });
  ["gb_one", "gb_two", "gb_three", "gb_four"].forEach((uid, i) => {
    b.set(db.doc("clients/" + uid), { uid, displayName: ["Асхат", "Болат", "Сауле", "Дана"][i], phone: "+7701000000" + i });
  });
  // 3 000 ₸/кг × 100 кг = 300 000 за целую тушу; 3 участника — по 100 000.
  const lot = {
    partnerId: "gb_farm", name: "Туша на троих", status: "open", bookedShares: 0, totalShares: 2,
    pricePerKg: 3000, totalWeight: 100, pricePerShare: 150000, animalIds: [],
  };
  ["GB1", "GB2", "GB3"].forEach((id) => b.set(db.doc("lots/" + id), lot));
  // 3 334 ₸/кг × 100 = 333 400 на четверых: 83 350 каждому, без остатка не делится ровно.
  b.set(db.doc("lots/GB4"), { ...lot, name: "Туша с остатком", pricePerKg: 3334 });
  await b.commit();

  const farmer = await idTokenFor("gb_farm", "+15550009601");
  const one = await idTokenFor("gb_one", "+15550009602");
  const two = await idTokenFor("gb_two", "+15550009603");
  const three = await idTokenFor("gb_three", "+15550009604");
  const four = await idTokenFor("gb_four", "+15550009605");

  const checks = [];
  const expectErr = async (label, promise, status) => {
    const res = await promise;
    const pass = !!res.error && res.error.status === status;
    checks.push([pass, label, pass ? "" : JSON.stringify(res)]);
  };
  const expectOk = async (label, promise, verify) => {
    const res = await promise;
    let pass = !!res.result;
    let info = JSON.stringify(res);
    if (pass && verify) {
      try { pass = await verify(res.result); } catch (e) { pass = false; info = String(e); }
    }
    checks.push([pass, label, pass ? "" : info]);
  };
  const group = async (id) => (await db.doc("groupBuys/" + id).get()).data();

  const create = async (token, lotId, size, extra = {}) => call("createGroupBuy", token, {
    lotId, format: "whole", size, deliveryId: "pickup", contactPhone: "+77010000001", ...extra,
  });

  // ---- gathering ------------------------------------------------------------------------------
  await expectErr("совместная покупка на одного", create(one, "GB1", 1), "INVALID_ARGUMENT");
  await expectErr("совместная покупка на шестерых", create(one, "GB1", 6), "INVALID_ARGUMENT");
  await expectErr("хозяйство собирает покупку своей туши", create(farmer, "GB1", 3), "FAILED_PRECONDITION");

  let G1 = null;
  await expectOk("организатор собирает тушу на троих: 300 000 делятся по 100 000", create(one, "GB1", 3), async (res) => {
    G1 = res.groupId;
    const g = await group(G1);
    const contact = (await db.doc(`groupBuys/${G1}/private/contact`).get()).data();
    const lot = (await db.doc("lots/GB1").get()).data();
    return g.status === "open" && g.size === 3 && g.amount === 300000
      && JSON.stringify(g.perMember) === JSON.stringify([100000, 100000, 100000])
      && g.members.length === 1 && g.memberUids[0] === "gb_one" && g.members[0].name === "Асхат"
      // Nothing is held while the group fills - the carcass is still on sale for everyone else.
      && lot.bookedShares === 0 && lot.status === "open"
      && contact.contactPhone === "+77010000001" && g.contactPhone === undefined;
  });

  await expectErr("организатор участвует дважды", call("joinGroupBuy", one, { groupId: G1 }), "FAILED_PRECONDITION");
  await expectErr("хозяйство участвует в своей туше", call("joinGroupBuy", farmer, { groupId: G1 }), "FAILED_PRECONDITION");
  await expectOk("второй участник: 2 из 3, заказа ещё нет", call("joinGroupBuy", two, { groupId: G1 }), async (res) => {
    const g = await group(G1);
    const orders = await db.collection("orders").where("lotId", "==", "GB1").get();
    return res.status === "open" && res.joined === 2 && g.members.length === 2 && orders.empty;
  });

  // ---- the last place places the order ---------------------------------------------------------
  let orderId = null;
  await expectOk("третий участник закрывает сбор — заказ уходит хозяйству", call("joinGroupBuy", three, { groupId: G1 }), async (res) => {
    orderId = res.orderId;
    const g = await group(G1);
    const o = (await db.doc("orders/" + orderId).get()).data();
    const lot = (await db.doc("lots/GB1").get()).data();
    return res.status === "placed" && g.status === "placed" && g.orderId === orderId
      && o.buyerUid === "gb_one" && o.amount === 300000 && o.group.size === 3
      && o.group.members.length === 3 && o.memberUids.includes("gb_three")
      && o.contactPhone === "+77010000001" && o.delivery.mode === "pickup"
      && lot.bookedShares === 2 && lot.status === "fully_booked";
  });
  await expectErr("выйти из собранной покупки", call("leaveGroupBuy", two, { groupId: G1 }), "FAILED_PRECONDITION");
  await expectErr("присоединиться к собранной покупке", call("joinGroupBuy", four, { groupId: G1 }), "FAILED_PRECONDITION");
  await expectErr("участник подтверждает получение за организатора",
    call("updateOrderStatus", two, { orderId, action: "complete" }), "PERMISSION_DENIED");

  // ---- everyone hears what happened -------------------------------------------------------------
  await expectOk("уведомления: хозяйству — заказ, каждому участнику — своя доля",
    Promise.resolve({ result: true }), async () => {
      const farmNotes = (await db.collection("notifications").where("uid", "==", "gb_farm").get()).docs.map((d) => d.data());
      const mine = (await db.collection("notifications").where("uid", "==", "gb_three").get()).docs.map((d) => d.data());
      return farmNotes.some((n) => n.kind === "order_new" && n.title.includes("совместная покупка"))
        && mine.some((n) => n.kind === "group_ready" && n.body.includes("100 000 ₸"));
    });

  // ---- leaving and cancelling --------------------------------------------------------------------
  let G2 = null;
  await expectOk("новый сбор на четверых", create(one, "GB2", 4), async (res) => { G2 = res.groupId; return true; });
  await call("joinGroupBuy", two, { groupId: G2 });
  await expectOk("участник выходит — место снова свободно", call("leaveGroupBuy", two, { groupId: G2 }), async (res) => {
    const g = await group(G2);
    return res.joined === 1 && g.members.length === 1 && !g.memberUids.includes("gb_two");
  });
  await expectErr("выходит тот, кто не участвует", call("leaveGroupBuy", three, { groupId: G2 }), "PERMISSION_DENIED");
  await call("joinGroupBuy", three, { groupId: G2 });
  await expectOk("организатор отменяет сбор — участники узнают", call("leaveGroupBuy", one, { groupId: G2 }), async () => {
    const g = await group(G2);
    const notes = (await db.collection("notifications").where("uid", "==", "gb_three").get()).docs.map((d) => d.data());
    return g.status === "cancelled" && notes.some((n) => n.kind === "group_failed" && n.title.includes("отменена"));
  });

  // ---- the carcass is sold while the group fills ---------------------------------------------------
  let G3 = null;
  await expectOk("сбор на тушу, которую вот-вот купят", create(one, "GB3", 2), async (res) => { G3 = res.groupId; return true; });
  await call("createOrder", four, {
    lotId: "GB3", format: "whole", deliveryId: "pickup", contactPhone: "+77010000004", idempotencyKey: "gb-race-key",
  });
  await expectOk("последнее место закрывается, но туша уже продана: сбор не состоялся",
    call("joinGroupBuy", two, { groupId: G3 }), async (res) => {
      const g = await group(G3);
      const notes = (await db.collection("notifications").where("uid", "==", "gb_two").get()).docs.map((d) => d.data());
      return res.status === "failed" && g.status === "failed" && !g.orderId
        && notes.some((n) => n.kind === "group_failed" && n.body.includes("Деньги никто не вносил"));
    });

  // ---- the odd tenge -------------------------------------------------------------------------------
  await expectOk("333 400 на четверых: остаток берёт организатор", create(one, "GB4", 4), async (res) => {
    const g = await group(res.groupId);
    const sum = g.perMember.reduce((a, x) => a + x, 0);
    return g.amount === 333400 && sum === 333400 && g.perMember[0] === 83350 && g.perMember[3] === 83350;
  });

  for (const [pass, label, info] of checks) console.log(`  ${pass ? "ok  " : "FAIL"}  ${label}${pass ? "" : "  " + info}`);
  const failed = checks.filter((c) => !c[0]).length;
  console.log(`\njoint purchase: ${checks.length - failed}/${checks.length} passed`);
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
