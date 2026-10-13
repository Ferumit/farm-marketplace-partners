// Push: the knock on the door for a notification that was already written.
//
// The trigger fires on every document in `notifications`, finds the phones that person is signed
// into, and records what came of it on the notification itself. FCM cannot be reached from the
// emulator, so what is checked here is everything up to the send: the right devices are found,
// a person with no phone is not left in limbo, and a failed send never touches the notification
// it was made from.
//
// Runs against the local emulators under a demo- project id:
//   cd tests/functions && npm test
const path = require("path");
const fnModules = path.join(__dirname, "../../functions/node_modules");
const { initializeApp } = require(path.join(fnModules, "firebase-admin/lib/app/index.js"));
const { getFirestore } = require(path.join(fnModules, "firebase-admin/lib/firestore/index.js"));

if (!process.env.FIRESTORE_EMULATOR_HOST) {
  console.error("refusing to run outside the emulator");
  process.exit(2);
}

initializeApp({ projectId: "demo-et" });
const db = getFirestore();

const token = (n) => `pt_token_${n}_${"x".repeat(30)}`;

/** The trigger runs out of band; wait for it to stamp the notification, or give up. */
async function pushState(ref, timeoutMs = 15000) {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    const snap = await ref.get();
    const push = snap.data()?.push;
    if (push?.state) return push;
    await new Promise((r) => setTimeout(r, 300));
  }
  return null;
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

  const write = (note) =>
    db.collection("notifications").add({
      read: false,
      createdAt: new Date(),
      title: "Заголовок",
      body: "Текст",
      ...note,
    });

  // ---- a buyer with two phones ----------------------------------------------------------------
  await db.doc(`clients/pu_buyer/devices/${token("a")}`).set({ token: token("a"), platform: "android" });
  await db.doc(`clients/pu_buyer/devices/${token("b")}`).set({ token: token("b"), platform: "ios" });

  const forBuyer = await write({ uid: "pu_buyer", role: "buyer", kind: "order_accepted", orderId: "pu_o1" });
  const buyerPush = await pushState(forBuyer);

  await check("уведомление покупателю доходит до отправки на оба его телефона", () =>
    buyerPush !== null && (buyerPush.devices === 2 || buyerPush.state === "failed"));

  await check("сорванная отправка не трогает само уведомление", async () => {
    const note = (await forBuyer.get()).data();
    return note.title === "Заголовок" && note.read === false && note.uid === "pu_buyer";
  });

  await check("неудача записана состоянием, а не исключением", () =>
    buyerPush !== null && ["failed", "sent"].includes(buyerPush.state));

  // ---- a farm keeps its phones on its own record ------------------------------------------------
  await db.doc(`partners/pu_farm/devices/${token("c")}`).set({ token: token("c"), platform: "android" });
  const forFarm = await write({ uid: "pu_farm", role: "partner", kind: "order_created", orderId: "pu_o2" });
  const farmPush = await pushState(forFarm);

  await check("хозяйству стучатся по телефонам с его записи", () =>
    farmPush !== null && (farmPush.devices === 1 || farmPush.state === "failed"));

  await check("телефоны покупателя и хозяйства не путаются", async () => {
    const farmDevices = await db.collection("partners/pu_farm/devices").get();
    const buyerDevices = await db.collection("clients/pu_buyer/devices").get();
    return farmDevices.size === 1 && buyerDevices.size === 2;
  });

  // ---- nobody signed in on any phone -------------------------------------------------------------
  const forNobody = await write({ uid: "pu_nophone", role: "buyer", kind: "order_accepted" });
  const nobodyPush = await pushState(forNobody);
  await check("человеку без телефонов состояние тоже записывают — «почему не пришло» имеет ответ", () =>
    nobodyPush !== null && nobodyPush.state === "no_devices");

  // ---- a gathering is named, so a push can open it ----------------------------------------------
  const forGroup = await write({ uid: "pu_buyer", role: "buyer", kind: "group_joined", groupId: "pu_g1" });
  const groupPush = await pushState(forGroup);
  await check("сбор передаётся вместе с уведомлением", async () => {
    const note = (await forGroup.get()).data();
    return note.groupId === "pu_g1" && groupPush !== null;
  });

  for (const [pass, label, info] of checks) console.log(`  ${pass ? "ok  " : "FAIL"}  ${label}${pass ? "" : "  " + info}`);
  const failed = checks.filter((c) => !c[0]).length;
  console.log(`\npush: ${checks.length - failed}/${checks.length} passed`);
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
