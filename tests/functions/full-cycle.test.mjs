// Полный круг — один непрерывный сюжет, от регистрации до отзыва.
//
// Чем он отличается от остальных тестов: здесь всё делается ВЕБ-SDK, тем же самым, что у сайта
// (firebase 10.14.1), а не Admin SDK. Значит, работают правила доступа: если хозяйство не может
// опубликовать свой лот или покупатель не видит каталог, тест упадёт — а Admin SDK этого не
// заметил бы никогда, потому что правила он обходит.
//
// Вход — кастом-токеном, а не кодом из SMS: SMS отправляет Firebase, а не мы, и для правил
// разницы нет. Всё остальное — настоящее: те же коллекции, те же поля, те же вызовы функций,
// тот же порядок, в котором их делает человек.
//
//   cd tests/functions && npm run test:cycle
import path from "node:path";
import http from "node:http";
import { pathToFileURL } from "node:url";

const here = path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, "$1"));
const root = path.join(here, "../..");
const webModules = path.join(root, "tests/rules/node_modules");
const fnModules = path.join(root, "functions/node_modules");
const load = (p) => import(pathToFileURL(path.join(webModules, p)).href);

if (!process.env.FIRESTORE_EMULATOR_HOST || !process.env.FIREBASE_AUTH_EMULATOR_HOST) {
  console.error("отказываюсь работать вне эмулятора");
  process.exit(2);
}

const { initializeApp } = await load("firebase/app/dist/index.mjs");
const FS = await load("firebase/firestore/dist/index.mjs");
const AU = await load("firebase/auth/dist/index.mjs");
const FN = await load("firebase/functions/dist/index.mjs");
const fp = await import(pathToFileURL(path.join(root, "functions/freedompay.js")).href);
const adminApp = await import(pathToFileURL(path.join(fnModules, "firebase-admin/lib/app/index.js")).href);
const adminStore = await import(pathToFileURL(path.join(fnModules, "firebase-admin/lib/firestore/index.js")).href);
const adminAuth = await import(pathToFileURL(path.join(fnModules, "firebase-admin/lib/auth/index.js")).href);

adminApp.initializeApp({ projectId: "demo-et" });
// Admin SDK здесь только для двух вещей: выдать токен (SMS отправляет Firebase, не мы) и
// посмотреть на результат глазами сервера. Ничего из сюжета он не делает — всё делает веб-SDK.
const server = adminStore.getFirestore();
const auth = adminAuth.getAuth();
const KEY = process.env.FREEDOMPAY_SECRET_PAY || "test_secret_key";

// ---- как это читает человек ---------------------------------------------------------------------
const results = [];
function check(label, ok, detail = "") {
  results.push(ok);
  console.log(`${ok ? "PASS" : "FAIL"}  ${label}${ok || !detail ? "" : "  (" + detail + ")"}`);
}
const act = (label, promise) => promise.then(
  (v) => { check(label, true); return v; },
  (e) => { check(label, false, e?.message || String(e)); throw e; },
);
const denied = async (label, promise) => {
  try {
    await promise;
    check(label, false, "прошло, хотя не должно было");
  } catch (e) {
    const code = e?.code || "";
    check(label, /permission-denied|PERMISSION_DENIED|failed-precondition/.test(code), code || String(e));
  }
};

// ---- отдельный «браузер» на каждого участника ----------------------------------------------------
// Разные экземпляры приложения — это разные вкладки с разными аккаунтами. Иначе вход хозяйства
// вытеснил бы вход покупателя, и половина проверок доступа была бы бутафорией.
function browser(name) {
  const app = initializeApp({ projectId: "demo-et", apiKey: "fake-key" }, name);
  const db = FS.initializeFirestore(app, {});
  FS.connectFirestoreEmulator(db, "127.0.0.1", 8085);
  const auth = AU.initializeAuth(app, { persistence: AU.inMemoryPersistence });
  AU.connectAuthEmulator(auth, "http://127.0.0.1:9099", { disableWarnings: true });
  const functions = FN.getFunctions(app, "europe-west3");
  FN.connectFunctionsEmulator(functions, "127.0.0.1", 5001);
  const callable = (fname) => async (data) => (await FN.httpsCallable(functions, fname)(data)).data;
  return { app, db, auth, call: callable };
}

async function signIn(b, uid, phone, claims = {}) {
  await auth.createUser({ uid, phoneNumber: phone }).catch(() => {});
  await AU.signInWithCustomToken(b.auth, await auth.createCustomToken(uid, claims));
  return uid;
}

// ---- заглушка Freedom Pay -------------------------------------------------------------------------
// Проверяет нашу подпись и отвечает их XML. Настоящий их сервер в тесте не участвует — но
// подпись, разбор ответа и порядок вызовов проверяются по-настоящему.
const sent = [];
let nextPaymentId = 80001;
const stub = http.createServer((req, res) => {
  let body = "";
  req.on("data", (c) => { body += c; });
  req.on("end", () => {
    const params = fp.parseCallbackBody(req.headers["content-type"], body);
    const script = fp.scriptNameOf(`http://x${req.url}`);
    res.setHeader("content-type", "application/xml");
    if (!fp.verify(script, params, KEY)) {
      res.end('<?xml version="1.0"?><response><pg_status>error</pg_status>'
        + "<pg_error_code>9998</pg_error_code></response>");
      return;
    }
    sent.push({ script, ...params });
    const fields = script === "init_payment.php"
      ? {
        pg_status: "ok", pg_payment_id: String(nextPaymentId++),
        pg_redirect_url: "https://pay.invalid/go", pg_redirect_url_type: "payment system",
      }
      : { pg_status: "ok" };
    res.end('<?xml version="1.0"?><response>'
      + Object.entries(fp.signed(script, fields, KEY))
        .map(([k, v]) => `<${k}>${String(v).replaceAll("&", "&amp;")}</${k}>`).join("")
      + "</response>");
  });
});
await new Promise((r) => stub.listen(Number(process.env.FREEDOMPAY_STUB_PORT || 8899), "127.0.0.1", r));

const FARM = "cy_farm";
const BUYER = "cy_buyer";
const STAFF = "cy_staff";

const anon = browser("anon");
const farm = browser("farm");
const buyer = browser("buyer");
const staff = browser("staff");

try {
  // ===== Акт 0. Аноним заходит на сайт ===========================================================
  // Сайт входит анонимно ещё до того, как человек что-то нажал: каталог открыт всем, но не
  // «вообще всем» — правила требуют хоть какой-то сессии.
  await act("аноним входит, как это делает сайт", AU.signInAnonymously(anon.auth));

  // ===== Акт 1. Хозяйство регистрируется =========================================================
  await signIn(farm, FARM, "+15550001001");
  const farmProfile = {
    uid: FARM, phone: "+15550001001", role: "partner", displayName: "КХ «Степной»",
    iin: null, iban: null, country: null, documentUrl: null, status: "pending_review",
    createdAt: FS.serverTimestamp(), avatarUrl: null, city: "Аршалы", rating: 0,
    totalDeals: 0, walletBalance: 0, pendingBalance: 0, achievements: [], regionCode: "KZ-11",
  };
  await act("хозяйство создаёт свой профиль",
    FS.setDoc(FS.doc(farm.db, "partners", FARM), farmProfile, { merge: true }));
  await act("ИИН уходит в закрытую запись, а не в публичный профиль",
    FS.setDoc(FS.doc(farm.db, "partners", FARM, "private", "identity"),
      { iin: "880101300123", updatedAt: FS.serverTimestamp() }));
  check("в публичном профиле ИИН нет",
    (await server.doc(`partners/${FARM}`).get()).data().iin === null);
  await denied("чужой профиль хозяйству не переписать",
    FS.setDoc(FS.doc(farm.db, "partners", "someone_else"), farmProfile, { merge: true }));
  await denied("чужой ИИН не прочитать",
    FS.getDoc(FS.doc(buyer.db, "partners", FARM, "private", "identity")));

  // Проверку платформы проходит сотрудник — без неё заказать у хозяйства нельзя.
  await server.doc(`staff/${STAFF}`).set({ uid: STAFF, role: "admin" });
  await signIn(staff, STAFF, "+15550001003", { role: "admin" });
  await act("сотрудник проверяет хозяйство",
    staff.call("reviewPartner")({ partnerId: FARM, decision: "approve" }));
  check("хозяйство аккредитовано",
    (await server.doc(`partners/${FARM}`).get()).data().status === "verified",
    (await server.doc(`partners/${FARM}`).get()).data().status);

  // ===== Акт 2. Витрина: доставка и разделка =====================================================
  const storefront = {
    description: "Мясо со своего пастбища, забой по заявке.",
    cutting: [{ id: "c1", name: "Порционная разделка", price: "8000", note: "в вакууме" }],
    delivery: [{ id: "d1", city: "Астана", price: "5000" }],
    pickup: true,
  };
  await act("хозяйство сохраняет витрину",
    FS.updateDoc(FS.doc(farm.db, "partners", FARM),
      { storefront, storefrontUpdatedAt: FS.serverTimestamp() }));

  // ===== Акт 3. Скот и бумаги ====================================================================
  const animalRef = FS.doc(FS.collection(farm.db, "animals"));
  await act("хозяйство заводит животное", FS.setDoc(animalRef, {
    partnerId: FARM, breed: "Казахская белоголовая", subBreed: "", status: "active",
    weight: 420, ageCategory: "young", gender: "male", type: "cattle", imageUrl: null,
    notes: null, vetDocuments: [], price: 1200000, region: "Акмолинская область",
    regionCode: "KZ-11", createdAt: FS.serverTimestamp(),
  }));
  await act("к животному прикладывают ветеринарную справку",
    FS.setDoc(FS.doc(farm.db, "animals", animalRef.id, "documents", "vet1"), {
      partnerId: FARM, animalId: animalRef.id, status: "pending",
      label: "Ветеринарная справка", fileUrl: "https://example.invalid/vet.pdf",
      fileName: "vet.pdf", contentType: "application/pdf", size: 120000,
      uploadedAt: FS.serverTimestamp(), reviewedAt: null, reviewedBy: null, reviewNote: null,
    }));

  // ===== Акт 4. Лот: черновик, потом публикация ==================================================
  const WEIGHT = 130;
  const PER_KG = 3500;
  const lotRef = FS.doc(FS.collection(farm.db, "lots"));
  await act("хозяйство собирает лот из этой туши", FS.setDoc(lotRef, {
    partnerId: FARM, name: "Казахская белоголовая, торпақ", description: "Туша целиком или половина.",
    animalIds: [animalRef.id], totalWeight: WEIGHT, pricePerKg: PER_KG,
    pricePerShare: Math.round((WEIGHT * PER_KG) / 2), status: "draft", totalShares: 2,
    bookedShares: 0, imageUrl: null, location: "Акмолинская область", regionCode: "KZ-11",
    meatType: "cattle", vetDocuments: [], createdAt: FS.serverTimestamp(),
  }));
  await denied("чужой лот постороннему не опубликовать",
    FS.updateDoc(FS.doc(buyer.db, "lots", lotRef.id), { status: "open" }));
  await act("хозяйство публикует лот",
    FS.updateDoc(FS.doc(farm.db, "lots", lotRef.id), { status: "open" }));
  await denied("забронированные доли с клиента не подрисовать",
    FS.updateDoc(FS.doc(farm.db, "lots", lotRef.id), { bookedShares: 2 }));

  // ===== Акт 5. Покупатель регистрируется ========================================================
  await signIn(buyer, BUYER, "+15550001002");
  await act("покупатель создаёт свой профиль",
    FS.setDoc(FS.doc(buyer.db, "clients", BUYER), {
      uid: BUYER, phone: "+15550001002", role: "client", displayName: "Асхат",
      iin: null, iban: null, country: null, documentUrl: null, status: "active",
      createdAt: FS.serverTimestamp(), avatarUrl: null, city: "Астана", rating: 0,
      totalDeals: 0, walletBalance: 0, pendingBalance: 0, achievements: [],
      email: "ashat@example.kz",
    }, { merge: true }));
  await denied("чужой профиль покупателя не прочитать",
    FS.getDoc(FS.doc(farm.db, "clients", BUYER)));

  // ===== Акт 6. Лот виден в каталоге =============================================================
  const catalogue = await FS.getDocs(FS.query(
    FS.collection(anon.db, "lots"), FS.where("status", "in", ["open", "fully_booked"])));
  check("лот появился в каталоге у постороннего",
    catalogue.docs.some((d) => d.id === lotRef.id), `видно лотов: ${catalogue.size}`);
  const seen = catalogue.docs.find((d) => d.id === lotRef.id)?.data();
  check("в каталоге видно вес и цену", seen?.totalWeight === WEIGHT && seen?.pricePerKg === PER_KG,
    JSON.stringify({ w: seen?.totalWeight, p: seen?.pricePerKg }));

  // ===== Акт 7. Заказ ============================================================================
  // Половина туши: 65 кг × 3 500 = 227 500, плюс разделка 8 000 и доставка 5 000.
  const EXPECTED = 227500 + 8000 + 5000;
  const made = await act("покупатель заказывает половину туши", buyer.call("createOrder")({
    lotId: lotRef.id, format: "half", cuttingId: "c1", deliveryId: "d1",
    deliveryAddress: "Астана, ул. Кунаева 12, кв. 5", contactPhone: "+77011234567",
    idempotencyKey: "cycle-order-key-0001",
  }));
  const orderId = made.orderId;
  const readOrder = async () => (await server.doc("orders/" + orderId).get()).data();
  let order = await readOrder();
  check("сумма собрана на сервере, а не принесена клиентом", order.amount === EXPECTED,
    `${order.amount} вместо ${EXPECTED}`);
  check("доля забронирована в лоте",
    (await server.doc("lots/" + lotRef.id).get()).data().bookedShares === 1);
  check("заказ ждёт оплаты", order.payment?.status === "awaiting", order.payment?.status);
  // План выплат появляется не здесь, а при принятии заказа: пока хозяйство не взяло заказ в
  // работу, делить нечего. На демо это видно именно так — плана нет, потом он есть.
  check("плана выплат до принятия заказа ещё нет", !order.payouts,
    JSON.stringify(order.payouts || null));
  check("хозяйство увидело заказ",
    (await server.collection("notifications").where("uid", "==", FARM)
      .where("orderId", "==", orderId).get()).size > 0);

  const repeat = await buyer.call("createOrder")({
    lotId: lotRef.id, format: "half", cuttingId: "c1", deliveryId: "d1",
    deliveryAddress: "Астана, ул. Кунаева 12, кв. 5", contactPhone: "+77011234567",
    idempotencyKey: "cycle-order-key-0001",
  });
  check("двойное нажатие не делает второй заказ", repeat.orderId === orderId,
    `${repeat.orderId} вместо ${orderId}`);

  // ===== Акт 8. Оплата ===========================================================================
  await denied("хозяйство не берёт в работу неоплаченный заказ",
    farm.call("updateOrderStatus")({ orderId, action: "accept" }));

  const started = await act("покупатель просит ссылку на оплату",
    buyer.call("startPayment")({ orderId }));
  check("ссылка на страницу оплаты получена", !!started.redirectUrl, JSON.stringify(started));
  const init = sent.find((s) => s.script === "init_payment.php");
  check("в Freedom ушла сумма заказа и просьба держать холд",
    init?.pg_amount === String(EXPECTED) && init?.pg_auto_clearing === "0",
    JSON.stringify({ amount: init?.pg_amount, clearing: init?.pg_auto_clearing }));

  const again = await buyer.call("startPayment")({ orderId });
  check("повторное нажатие даёт ту же ссылку, а не второй платёж",
    again.redirectUrl === started.redirectUrl
    && sent.filter((s) => s.script === "init_payment.php").length === 1);

  // Уведомление от Freedom — единственное, что меняет статус. Редиректу не верим.
  const notify = async (fields) => {
    const r = await fetch("http://127.0.0.1:5001/demo-et/europe-west3/freedompayResult", {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams(fp.signed("freedompayResult", fields, KEY)).toString(),
    });
    return r.text();
  };
  await notify({
    pg_order_id: orderId, pg_payment_id: started.paymentId,
    pg_amount: EXPECTED, pg_result: 1, pg_can_reject: "0",
  });
  order = await readOrder();
  check("деньги заблокированы на карте, но не списаны",
    order.payment?.status === "authorized" && order.payment?.authorizedAmount === EXPECTED,
    JSON.stringify(order.payment || {}));
  check("покупателю сообщили об оплате",
    (await server.collection("notifications").where("uid", "==", BUYER)
      .where("kind", "==", "order_paid").get()).size > 0);

  const forged = await fetch("http://127.0.0.1:5001/demo-et/europe-west3/freedompayResult", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ pg_order_id: orderId, pg_result: "1", pg_sig: "0".repeat(32) }).toString(),
  });
  check("поддельное уведомление отвергается", forged.status === 403, String(forged.status));

  // ===== Акт 9. Хозяйство ведёт заказ ============================================================
  await act("хозяйство принимает заказ",
    farm.call("updateOrderStatus")({ orderId, action: "accept" }));
  order = await readOrder();
  check("в этот момент деньги списались с карты",
    order.payment?.status === "captured_full" && order.payment?.capturedAmount === EXPECTED,
    JSON.stringify(order.payment || {}));
  check("клиринг ушёл в Freedom на ту же сумму",
    sent.some((s) => s.script === "do_capture.php" && s.pg_clearing_amount === String(EXPECTED)),
    JSON.stringify(sent.filter((s) => s.script === "do_capture.php")));
  check("аванс 50 % открылся хозяйству",
    order.payouts?.advance?.status === "unlocked",
    JSON.stringify(order.payouts?.advance || {}));

  const file = (name, kind) => ({
    kind, name,
    url: "http://127.0.0.1:9199/v0/b/demo-et.appspot.com/o/"
      + encodeURIComponent(`orders/${FARM}/${orderId}/${name}`) + "?alt=media&token=t",
  });
  await denied("покупатель не может вести шаги за хозяйство",
    buyer.call("updateOrderStatus")({ orderId, action: "identify", files: [file("x.jpg", "photo")] }));
  await act("шаг 1: животное показано",
    farm.call("updateOrderStatus")({ orderId, action: "identify", files: [file("animal.mp4", "video")] }));

  // Контрольное взвешивание: 63 кг вместо расчётных 65. Заказ дешевеет на 7 000.
  await act("шаг 2: мясо готово, на весах 63 кг",
    farm.call("updateOrderStatus")({
      orderId, action: "meat_ready",
      files: [file("meat.jpg", "photo")], documents: [file("vet.pdf", "doc")],
      scalePhoto: file("scale.jpg", "photo"), weightKg: 63,
    }));
  order = await readOrder();
  check("пересчёт по факту: разница −7 000",
    order.weighing?.difference === -7000 && order.weighing?.weightKg === 63,
    JSON.stringify(order.weighing || {}));
  check("разница вернулась покупателю на карту",
    sent.some((s) => s.script === "revoke.php" && s.pg_refund_amount === "7000"),
    JSON.stringify(sent.filter((s) => s.script === "revoke.php")));
  check("заказ остался оплаченным, вернули только разницу",
    order.payment?.status === "captured_partial" && order.payment?.refundedAmount === 7000,
    JSON.stringify(order.payment || {}));
  check("вторая четверть открылась хозяйству",
    order.payouts?.meat?.status === "unlocked", JSON.stringify(order.payouts?.meat || {}));
  check("ветеринарные бумаги животного приехали к покупателю",
    (order.steps?.meat?.certificates || []).length === 1,
    JSON.stringify(order.steps?.meat?.certificates || []));

  await act("шаг 3: заказ отправлен",
    farm.call("updateOrderStatus")({ orderId, action: "ship" }));
  await act("шаг 4: заказ передан покупателю",
    farm.call("updateOrderStatus")({ orderId, action: "handover" }));
  order = await readOrder();
  check("у покупателя есть три часа на подтверждение",
    order.autoCompleteAt.toMillis() - Date.now() > 2.9 * 3600e3);

  // ===== Акт 10. Покупатель закрывает круг =======================================================
  await denied("хозяйство не может подтвердить получение за покупателя",
    farm.call("updateOrderStatus")({ orderId, action: "complete" }));
  await act("покупатель подтверждает получение",
    buyer.call("updateOrderStatus")({ orderId, action: "complete" }));
  order = await readOrder();
  check("сделка завершена, последняя четверть открылась",
    order.status === "completed" && order.payouts?.final?.status === "unlocked",
    `${order.status} / ${order.payouts?.final?.status}`);
  check("хозяйству засчитана сделка",
    (await server.doc(`partners/${FARM}`).get()).data().totalDeals === 1);
  // Хозяйству причитается то, что покупатель заплатил ПОСЛЕ пересчёта, минус комиссия 10 %.
  const paid = EXPECTED - 7000;
  const net = Math.round(paid * 0.9);
  const parts = order.payouts.advance.amount + order.payouts.meat.amount + order.payouts.final.amount;
  check("выплаты сошлись с тем, что реально заплатил покупатель",
    order.payouts.net === net && parts === net,
    JSON.stringify({ net: order.payouts.net, ожидали: net, сумма_частей: parts, заплачено: paid }));

  // ===== Акт 11. Отзыв ===========================================================================
  await act("покупатель оставляет отзыв",
    buyer.call("submitReview")({ orderId, rating: 5, text: "Мясо отличное, хозяйство на связи" }));
  check("отзыв ждёт модерации и пока не двигает рейтинг",
    (await server.doc("reviews/" + orderId).get()).data().status === "pending"
    && (await server.doc(`partners/${FARM}`).get()).data().rating === 0);
  await act("модератор публикует отзыв",
    staff.call("moderateReview")({ reviewId: orderId, decision: "approve" }));
  check("рейтинг хозяйства стал 5",
    (await server.doc(`partners/${FARM}`).get()).data().rating === 5,
    String((await server.doc(`partners/${FARM}`).get()).data().rating));

  // ===== Акт 12. Лот снова свободен ==============================================================
  check("вторая половина туши осталась в продаже",
    (await server.doc("lots/" + lotRef.id).get()).data().bookedShares === 1
    && (await server.doc("lots/" + lotRef.id).get()).data().status === "open");
} catch (e) {
  check("сюжет дошёл до конца", false, e?.message || String(e));
} finally {
  stub.close();
}

const failed = results.filter((r) => !r).length;
console.log(failed ? `${failed} ПРОВАЛЕНО из ${results.length}` : `весь круг пройден: ${results.length} проверок`);
process.exit(failed ? 1 : 0);
