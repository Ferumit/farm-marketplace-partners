// Оплата Freedom Pay: запрос ссылки, вопрос перед списанием и уведомление о результате.
//
// Живой сервис здесь не участвует. Вместо него поднимается заглушка их init_payment, которая
// проверяет НАШУ подпись их же алгоритмом и отвечает их же XML. Это и есть смысл теста: убедиться,
// что мы шлём правильно подписанный запрос с суммой ИЗ ЗАКАЗА, а не из того, что прислал клиент.
//
// Вебхуки дёргаются напрямую, как их дёргает Freedom Pay: формой, подписанной ключом. Проверяется
// в том числе то, ради чего всё и писалось, — что без подписи в базу не попадает ничего.
//
// Запуск (нужны эмуляторы и ET_PAYMENTS=on):
//   cd tests/functions && npm run test:payments
const path = require("path");
const http = require("http");
const fnModules = path.join(__dirname, "../../functions/node_modules");
const { initializeApp } = require(path.join(fnModules, "firebase-admin/lib/app/index.js"));
const { getFirestore, Timestamp } = require(path.join(fnModules, "firebase-admin/lib/firestore/index.js"));
const { getAuth } = require(path.join(fnModules, "firebase-admin/lib/auth/index.js"));

if (!process.env.FIRESTORE_EMULATOR_HOST || !process.env.FIREBASE_AUTH_EMULATOR_HOST) {
  console.error("refusing to run outside the emulator");
  process.exit(2);
}

const KEY = process.env.FREEDOMPAY_SECRET_PAY;
if (!KEY) {
  console.error("нет FREEDOMPAY_SECRET_PAY — тест подписывает запросы тем же ключом, что функции");
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

const results = [];
function check(label, ok, detail = "") {
  results.push(ok);
  console.log(`${ok ? "PASS" : "FAIL"}  ${label}${detail ? "  (" + detail + ")" : ""}`);
}

(async () => {
  const fp = await import("file://" + path.join(__dirname, "../../functions/freedompay.js").replace(/\\/g, "/"));

  // ---- заглушка их init_payment ---------------------------------------------------------------
  // Проверяет нашу подпись и отвечает их XML. Запоминает последний запрос, чтобы тест мог
  // заглянуть внутрь: какую сумму мы на самом деле отправили и какой режим клиринга попросили.
  let lastRequest = null;
  const captures = [];
  let nextPaymentId = 90001;
  const stub = http.createServer((req, res) => {
    let body = "";
    req.on("data", (c) => { body += c; });
    req.on("end", () => {
      const params = fp.parseCallbackBody(req.headers["content-type"], body);
      res.setHeader("content-type", "application/xml");

      // Имя скрипта берём из адреса, как это делает их сервер: подпись считается по нему, и
      // проверять init_payment подписью do_capture нельзя.
      const script = fp.scriptNameOf(`http://x${req.url}`);
      const reply = (fields) => res.end('<?xml version="1.0"?><response>'
        + Object.entries(fp.signed(script, fields, KEY)).map(([k, v]) => `<${k}>${v}</${k}>`).join("")
        + "</response>");

      if (!fp.verify(script, params, KEY)) {
        res.end('<?xml version="1.0"?><response><pg_status>error</pg_status>'
          + "<pg_error_code>9998</pg_error_code>"
          + "<pg_error_description>Некорректная подпись запроса</pg_error_description></response>");
        return;
      }

      // Клиринг: списание холда. Запоминаем, по какому платежу и на какую сумму пришли, —
      // тест проверяет и то, и другое.
      if (script === "do_capture.php" || script === "cancel.php" || script === "revoke.php") {
        captures.push({ script, ...params });
        reply({ pg_status: "ok" });
        return;
      }

      lastRequest = params;
      const id = String(nextPaymentId++);
      const answer = fp.signed("init_payment.php", {
        pg_status: "ok",
        pg_payment_id: id,
        pg_redirect_url: `https://pay.invalid/${id}`,
        pg_redirect_url_type: "payment system",
      }, KEY);
      res.end('<?xml version="1.0"?><response>'
        + Object.entries(answer).map(([k, v]) => `<${k}>${String(v).replaceAll("&", "&amp;")}</${k}>`).join("")
        + "</response>");
    });
  });
  // Порт фиксирован: функции живут в другом процессе и узнают адрес заглушки из окружения,
  // которое выставил run-payments.cjs ещё до старта эмулятора.
  const STUB_PORT = Number(process.env.FREEDOMPAY_STUB_PORT || 8899);
  await new Promise((r) => stub.listen(STUB_PORT, "127.0.0.1", r));

  // ---- данные ---------------------------------------------------------------------------------
  const TOTAL = 227500;
  const order = (id, extra = {}) => ({
    buyerUid: "pay_buyer", buyerPhone: "+15550009401", partnerId: "pay_farm",
    lotId: "PAY1", lotTitle: "Казахская белоголовая, торпақ", shares: 1,
    amount: TOTAL, currency: "KZT", format: "half",
    status: "created", statusHistory: [],
    payment: {
      status: "awaiting", provider: null, providerPaymentId: null, method: null,
      authorizedAmount: 0, capturedAmount: 0, refundedAmount: 0,
      authorizedAt: null, capturedAt: null, refundedAt: null,
    },
    contactPhone: "+77000000014",
    createdAt: Timestamp.now(), updatedAt: Timestamp.now(), paidAt: null,
    ...extra,
  });

  const batch = db.batch();
  batch.set(db.doc("partners/pay_farm"), {
    uid: "pay_farm", displayName: "КХ Оплата", status: "verified",
    storefront: { cutting: [], delivery: [{ id: "d1", city: "Астана", price: 5000 }], pickup: true },
  });
  // Лоты для настоящего createOrder: только через него проходит initialPayment, а значит и
  // решение, платит этот покупатель онлайн или рассчитывается с хозяйством напрямую.
  const lot = {
    partnerId: "pay_farm", name: "Туша на оплату", status: "open", bookedShares: 0, totalShares: 2,
    pricePerKg: 3500, totalWeight: 130, pricePerShare: 227500, animalIds: [],
  };
  batch.set(db.doc("lots/PAY_LOT"), lot);
  batch.set(db.doc("lots/PAY_LOT_G"), { ...lot, totalShares: 2 });
  batch.set(db.doc("orders/PAY_OK"), order("PAY_OK"));
  batch.set(db.doc("orders/PAY_REUSE"), order("PAY_REUSE"));
  batch.set(db.doc("orders/PAY_GROUP"), order("PAY_GROUP", {
    group: { size: 2, members: [{ uid: "pay_buyer" }, { uid: "pay_other" }] },
    memberUids: ["pay_buyer", "pay_other"],
  }));
  batch.set(db.doc("orders/PAY_HOOK"), order("PAY_HOOK"));
  batch.set(db.doc("orders/PAY_AMOUNT"), order("PAY_AMOUNT"));
  batch.set(db.doc("orders/PAY_FAIL"), order("PAY_FAIL"));
  batch.set(db.doc("orders/PAY_CHECK"), order("PAY_CHECK"));
  batch.set(db.doc("orders/PAY_GATE"), order("PAY_GATE"));
  batch.set(db.doc("orders/PAY_HOLD"), order("PAY_HOLD"));
  batch.set(db.doc("orders/PAY_PAID"), order("PAY_PAID", {
    payment: { ...order("x").payment, status: "authorized" },
  }));
  await batch.commit();

  const buyer = await idTokenFor("pay_buyer", "+15550009401");
  const stranger = await idTokenFor("pay_stranger", "+15550009402");
  // Участник складчины, который НЕ организатор: заказ он видит, но платит не он.
  const member = await idTokenFor("pay_other", "+15550009403");
  const readOrder = async (id) => (await db.doc("orders/" + id).get()).data();

  // ---- кто платит онлайн -------------------------------------------------------------------------
  // Решение принимается в createOrder и записывается НА ЗАКАЗ. Здесь оно проверяется на настоящем
  // пути, а не на заказе, собранном руками: именно тут живёт разница между покупателем, с которого
  // берут деньги, и пилотом, где расчёт идёт напрямую с хозяйством.
  const made = await call("createOrder", buyer, {
    lotId: "PAY_LOT", format: "half", deliveryId: "d1",
    deliveryAddress: "Астана, ул. Тестовая 1", contactPhone: "+77000000000",
    idempotencyKey: "pay-key-1",
  });
  const madeOrder = made.result?.orderId ? await readOrder(made.result.orderId) : null;
  check("заказ платящего покупателя ждёт оплаты",
    madeOrder?.payment?.status === "awaiting",
    JSON.stringify(made.error || madeOrder?.payment?.status));

  // Складчина платит онлайн наравне с обычным заказом: всю сумму вносит организатор. Проверяется
  // на настоящем пути — через createGroupBuy и joinGroupBuy, а не на заказе, собранном руками:
  // именно в createOrder принимается и записывается решение, платит этот заказ онлайн или нет.
  const madeGroup = await call("createGroupBuy", buyer, {
    lotId: "PAY_LOT_G", format: "whole", size: 2, deliveryId: "pickup",
    contactPhone: "+77000000000",
  });
  // Заказ у сбора появляется только когда сошлись все участники, поэтому доводим сбор до конца
  // вторым покупателем — иначе проверка прошла бы вхолостую.
  const buyer2 = await idTokenFor("pay_buyer2", "+15550009404");
  const joined = await call("joinGroupBuy", buyer2, { groupId: madeGroup.result?.groupId });
  const groupOrder = joined.result?.orderId ? await readOrder(joined.result.orderId) : null;
  check("складчина ждёт оплаты, как обычный заказ",
    groupOrder?.payment?.status === "awaiting",
    JSON.stringify(joined.error || groupOrder?.payment?.status || "заказа нет"));
  check("платит организатор: заказ записан на него",
    groupOrder?.buyerUid === "pay_buyer" && (groupOrder?.memberUids || []).includes("pay_buyer2"),
    JSON.stringify({ buyerUid: groupOrder?.buyerUid, memberUids: groupOrder?.memberUids }));

  // ---- startPayment ---------------------------------------------------------------------------
  const foreign = await call("startPayment", stranger, { orderId: "PAY_OK" });
  check("чужой заказ оплатить нельзя", foreign.error?.status === "PERMISSION_DENIED",
    JSON.stringify(foreign.error || foreign.result));

  // ---- складчину оплачивает организатор ----------------------------------------------------------
  // Полной суммой за всех, доли он собирает сам. N холдов на один заказ модель не умеет, и вместо
  // того чтобы делать вид, что умеет, выбран путь без единой новой денежной ветки: заказ платится
  // ровно так же, как заказ на одного.
  const groupPay = await call("startPayment", buyer, { orderId: "PAY_GROUP" });
  check("организатор складчины получает ссылку на оплату",
    typeof groupPay.result?.redirectUrl === "string",
    JSON.stringify(groupPay.error || groupPay.result));
  check("платится весь заказ, а не доля организатора",
    lastRequest.pg_order_id === "PAY_GROUP" && Number(lastRequest.pg_amount) === TOTAL,
    `${lastRequest.pg_order_id} / ${lastRequest.pg_amount}`);

  // Кнопку участнику не показывают ни сайт, ни приложение — но запрет должен жить на сервере,
  // а не в разметке: отказ проверяем здесь.
  const byMember = await call("startPayment", member, { orderId: "PAY_GROUP" });
  check("участник складчины платить не может, и ему объясняют почему",
    byMember.error?.status === "PERMISSION_DENIED"
    && String(byMember.error?.message || "").includes("организатор"),
    JSON.stringify(byMember.error || byMember.result));

  const byStranger = await call("startPayment", stranger, { orderId: "PAY_GROUP" });
  check("посторонний по складчине получает обычный отказ, без лишних подробностей",
    byStranger.error?.status === "PERMISSION_DENIED"
    && String(byStranger.error?.message || "").includes("Это не ваш заказ"),
    JSON.stringify(byStranger.error || byStranger.result));

  const started = await call("startPayment", buyer, { orderId: "PAY_OK" });
  check("ссылка на оплату получена", typeof started.result?.redirectUrl === "string"
    && started.result.redirectUrl.startsWith("https://pay.invalid/"),
    JSON.stringify(started.error || started.result));

  if (lastRequest) {
    check("подпись нашего запроса принята заглушкой",
      fp.verify("init_payment.php", lastRequest, KEY));
    check("сумма взята из заказа, а не из клиента", Number(lastRequest.pg_amount) === TOTAL,
      lastRequest.pg_amount);
    check("заказ отправлен двухстадийным (холд, не списание)",
      String(lastRequest.pg_auto_clearing) === "0", lastRequest.pg_auto_clearing);
    check("номер заказа наш", lastRequest.pg_order_id === "PAY_OK");
    check("тестовый режим включён", String(lastRequest.pg_testing_mode) === "1");
    check("result_url и check_url заданы",
      !!lastRequest.pg_result_url && !!lastRequest.pg_check_url,
      `${lastRequest.pg_result_url} | ${lastRequest.pg_check_url}`);
  }

  const afterStart = await readOrder("PAY_OK");
  check("заказ помнит платёж", afterStart.payment?.provider === "freedompay"
    && !!afterStart.payment?.providerPaymentId && afterStart.payment?.status === "awaiting");

  const again = await call("startPayment", buyer, { orderId: "PAY_OK" });
  check("повторное нажатие не заводит второй платёж",
    again.result?.redirectUrl === started.result?.redirectUrl,
    `${started.result?.redirectUrl} vs ${again.result?.redirectUrl}`);

  const paid = await call("startPayment", buyer, { orderId: "PAY_PAID" });
  check("оплаченный заказ повторно не оплатить", paid.error?.status === "FAILED_PRECONDITION",
    JSON.stringify(paid.error || paid.result));

  // ---- вебхук: подпись --------------------------------------------------------------------------
  const post = async (name, params) => {
    const body = new URLSearchParams();
    for (const [k, v] of Object.entries(params)) body.append(k, String(v));
    const r = await fetch(FN(name), {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body,
    });
    return { status: r.status, text: await r.text() };
  };

  const forged = await post("freedompayResult", {
    pg_order_id: "PAY_HOOK", pg_payment_id: "666", pg_amount: TOTAL, pg_result: 1,
    pg_salt: "zzz", pg_sig: "0".repeat(32),
  });
  check("уведомление без подписи отвергается", forged.status === 403, String(forged.status));
  const untouched = await readOrder("PAY_HOOK");
  check("после поддельного уведомления заказ не тронут",
    untouched.payment?.status === "awaiting" && !(await db.doc("payments/666").get()).exists);

  // ---- вебхук: успех ----------------------------------------------------------------------------
  const okParams = fp.signed("freedompayResult", {
    pg_order_id: "PAY_HOOK", pg_payment_id: "70001", pg_amount: TOTAL, pg_currency: "KZT",
    pg_result: 1, pg_can_reject: 0, pg_captured: 0, pg_payment_method: "bankcard",
    pg_card_pan: "444444******6666", pg_testing_mode: 1,
    pg_payment_date: "2026-09-30 21:15:00",
  }, KEY);
  const okRes = await post("freedompayResult", okParams);
  const okXml = fp.parseXml(okRes.text);
  check("на верное уведомление отвечаем 200 и их XML",
    okRes.status === 200 && okXml.pg_status === "ok", `${okRes.status} ${okXml.pg_status}`);
  check("наш ответ подписан правильно", fp.verify("freedompayResult", okXml, KEY));

  const hooked = await readOrder("PAY_HOOK");
  check("заказ перешёл в авторизован", hooked.payment?.status === "authorized",
    hooked.payment?.status);
  check("сумма авторизации записана", hooked.payment?.authorizedAmount === TOTAL);
  check("ссылка на оплату погашена", hooked.payment?.redirectUrl === null);

  const ledger = (await db.doc("payments/70001").get()).data();
  check("в журнале платежей появилась запись",
    ledger?.orderId === "PAY_HOOK" && ledger?.buyerUid === "pay_buyer"
    && ledger?.partnerId === "pay_farm" && ledger?.amount === TOTAL && ledger?.result === 1,
    JSON.stringify(ledger || {}));

  // ---- обе стороны узнали об оплате ----------------------------------------------------------------
  const notesFor = async (uid, orderId) => {
    const snap = await db.collection("notifications")
      .where("uid", "==", uid).where("orderId", "==", orderId).get();
    return snap.docs.map((d) => d.data());
  };
  const farmNotes = await notesFor("pay_farm", "PAY_HOOK");
  const buyerNotes = await notesFor("pay_buyer", "PAY_HOOK");
  check("хозяйство узнало об оплате",
    farmNotes.some((n) => n.kind === "order_paid" && n.link === "/cabinet/order?id=PAY_HOOK"),
    JSON.stringify(farmNotes.map((n) => n.kind)));
  check("покупатель тоже узнал",
    buyerNotes.some((n) => n.kind === "order_paid" && n.link === "/order?id=PAY_HOOK"),
    JSON.stringify(buyerNotes.map((n) => n.kind)));
  check("хозяйству не обещают денег, которых ещё нет",
    farmNotes.some((n) => n.kind === "order_paid" && /можно принимать/.test(n.body || "")));

  // ---- вебхук: повтор ----------------------------------------------------------------------------
  await db.doc("orders/PAY_HOOK").update({ "payment.status": "awaiting" });
  const repeat = await post("freedompayResult", okParams);
  check("повтор того же уведомления отвечает ok",
    fp.parseXml(repeat.text).pg_status === "ok");
  const afterRepeat = await readOrder("PAY_HOOK");
  check("повтор ничего не меняет", afterRepeat.payment?.status === "awaiting",
    afterRepeat.payment?.status);
  // Уведомление приходит повторно каждые полчаса два часа подряд. Если бы дубль доходил до
  // записи, хозяйство получило бы четыре пуша об одной оплате.
  const farmAfterRepeat = await notesFor("pay_farm", "PAY_HOOK");
  check("повтор не шлёт второе уведомление",
    farmAfterRepeat.filter((n) => n.kind === "order_paid").length === 1,
    String(farmAfterRepeat.filter((n) => n.kind === "order_paid").length));

  // ---- вебхук: чужая сумма ------------------------------------------------------------------------
  const wrongAmount = fp.signed("freedompayResult", {
    pg_order_id: "PAY_AMOUNT", pg_payment_id: "70002", pg_amount: 1, pg_result: 1, pg_can_reject: 1,
  }, KEY);
  const wrongRes = await post("freedompayResult", wrongAmount);
  check("платёж не на ту сумму отклоняется",
    fp.parseXml(wrongRes.text).pg_status === "rejected", wrongRes.text.slice(0, 120));
  const amountOrder = await readOrder("PAY_AMOUNT");
  check("заказ с чужой суммой не оплачен", amountOrder.payment?.status === "awaiting");

  // ---- вебхук: отказ ------------------------------------------------------------------------------
  const failed = fp.signed("freedompayResult", {
    pg_order_id: "PAY_FAIL", pg_payment_id: "70003", pg_amount: TOTAL, pg_result: 0,
    pg_failure_code: "1001",
  }, KEY);
  await post("freedompayResult", failed);
  const failOrder = await readOrder("PAY_FAIL");
  check("отказ записан как failed", failOrder.payment?.status === "failed", failOrder.payment?.status);
  check("код отказа сохранён", failOrder.payment?.failureCode === "1001");
  const failNotes = await notesFor("pay_buyer", "PAY_FAIL");
  check("покупателю сказали, что оплата не прошла",
    failNotes.some((n) => n.kind === "payment_failed"),
    JSON.stringify(failNotes.map((n) => n.kind)));
  check("хозяйству про неудачную оплату не пишут",
    (await notesFor("pay_farm", "PAY_FAIL")).length === 0);

  // ---- check_url ------------------------------------------------------------------------------------
  const checkOk = await post("freedompayCheck", fp.signed("freedompayCheck", {
    pg_order_id: "PAY_CHECK", pg_payment_id: "70004", pg_amount: TOTAL,
  }, KEY));
  check("на свободный заказ отвечаем ok", fp.parseXml(checkOk.text).pg_status === "ok",
    checkOk.text.slice(0, 120));

  const checkPaid = await post("freedompayCheck", fp.signed("freedompayCheck", {
    pg_order_id: "PAY_PAID", pg_payment_id: "70005", pg_amount: TOTAL,
  }, KEY));
  check("на уже оплаченный отвечаем rejected",
    fp.parseXml(checkPaid.text).pg_status === "rejected", checkPaid.text.slice(0, 120));

  const checkGone = await post("freedompayCheck", fp.signed("freedompayCheck", {
    pg_order_id: "НЕТ_ТАКОГО", pg_payment_id: "70006", pg_amount: TOTAL,
  }, KEY));
  check("на несуществующий заказ отвечаем rejected",
    fp.parseXml(checkGone.text).pg_status === "rejected");

  const checkForged = await post("freedompayCheck", {
    pg_order_id: "PAY_CHECK", pg_amount: TOTAL, pg_salt: "z", pg_sig: "0".repeat(32),
  });
  check("вопрос без подписи отвергается", checkForged.status === 403);

  // ---- ради чего всё и разделено на две оси ------------------------------------------------------
  // Фулфилмент и деньги независимы, но в одной точке связаны: хозяйство не начинает работу по
  // неоплаченному заказу. Пока оплата выключена, эта связь спит и потому не проверена ничем —
  // здесь она включена, и её надо увидеть работающей.
  const farmer = await idTokenFor("pay_farm", "+15550009403");
  const tooEarly = await call("updateOrderStatus", farmer, { orderId: "PAY_GATE", action: "accept" });
  check("хозяйство не берёт в работу неоплаченный заказ",
    tooEarly.error?.status === "FAILED_PRECONDITION"
    && String(tooEarly.error?.message || "").includes("не оплачен"),
    JSON.stringify(tooEarly.error || tooEarly.result));

  await post("freedompayResult", fp.signed("freedompayResult", {
    pg_order_id: "PAY_GATE", pg_payment_id: "70007", pg_amount: TOTAL, pg_result: 1,
  }, KEY));
  const gatePaid = await readOrder("PAY_GATE");
  check("после оплаты заказ авторизован", gatePaid.payment?.status === "authorized",
    gatePaid.payment?.status);

  const nowCan = await call("updateOrderStatus", farmer, { orderId: "PAY_GATE", action: "accept" });
  check("после оплаты хозяйство берёт заказ в работу",
    nowCan.result?.status === "accepted", JSON.stringify(nowCan.error || nowCan.result));
  const accepted = await readOrder("PAY_GATE");
  check("аванс 50 % открылся вместе с принятием",
    accepted.payouts?.advance?.status === "unlocked",
    JSON.stringify(accepted.payouts?.advance || {}));

  // ---- списание холда при принятии заказа ----------------------------------------------------
  // Момент, ради которого вся двухстадийность: деньги уходят ровно тогда, когда хозяйство взяло
  // заказ в работу, — не раньше (иначе платим за несостоявшуюся сделку) и не позже (иначе через
  // пять суток Freedom спишет сам, и мы узнаем об этом последними).
  check("при принятии заказа ушёл клиринг", captures.length === 1, String(captures.length));
  if (captures.length) {
    check("клиринг по тому платежу и на ту сумму",
      captures[0].pg_payment_id === "70007" && Number(captures[0].pg_clearing_amount) === TOTAL,
      `${captures[0].pg_payment_id} / ${captures[0].pg_clearing_amount}`);
  }
  check("заказ помечен списанным", accepted.payment?.status === "captured_full",
    accepted.payment?.status);
  check("сумма списания записана", accepted.payment?.capturedAmount === TOTAL);
  check("следа ошибки клиринга нет", !accepted.payment?.captureError);

  // Неоплаченный заказ клиринга не вызывает: списывать нечего.
  const beforeCount = captures.length;
  await call("updateOrderStatus", farmer, { orderId: "PAY_CHECK", action: "accept" }).catch(() => {});
  check("по неоплаченному заказу клиринга не было", captures.length === beforeCount,
    String(captures.length));

  // ---- отмена: снять холд или вернуть списанное -------------------------------------------------
  // Два разных запроса, и перепутать их нельзя: неклиренный холд снимается `cancel`, а по
  // списанному платежу `cancel` уже не работает — нужен `revoke`.
  const held = await call("startPayment", buyer, { orderId: "PAY_HOLD" });
  check("заказ под отмену оплачен", !!held.result?.redirectUrl,
    JSON.stringify(held.error || held.result));
  await post("freedompayResult", fp.signed("freedompayResult", {
    pg_order_id: "PAY_HOLD", pg_payment_id: "70010", pg_amount: TOTAL, pg_result: 1,
  }, KEY));

  const beforeCancel = captures.length;
  const cancelled = await call("updateOrderStatus", buyer, { orderId: "PAY_HOLD", action: "cancel" });
  check("покупатель отменяет оплаченный, но не списанный заказ",
    cancelled.result?.status === "cancelled", JSON.stringify(cancelled.error || cancelled.result));
  const holdCall = captures[beforeCancel];
  check("по неклиренному холду ушёл cancel, а не revoke",
    holdCall?.script === "cancel.php" && holdCall?.pg_payment_id === "70010",
    JSON.stringify(holdCall || {}));
  const afterCancel = await readOrder("PAY_HOLD");
  check("холд снят, деньги не списаны", afterCancel.payment?.status === "cancelled",
    afterCancel.payment?.status);

  // Списанный платёж: возврат.
  const refundOrder = await readOrder("PAY_GATE");
  check("перед возвратом заказ списан", refundOrder.payment?.status === "captured_full");
  const beforeRefund = captures.length;
  await db.doc("orders/PAY_GATE").update({ status: "created" });
  const refunded = await call("updateOrderStatus", buyer, { orderId: "PAY_GATE", action: "cancel" });
  check("покупатель отменяет списанный заказ", refunded.result?.status === "cancelled",
    JSON.stringify(refunded.error || refunded.result));
  const refundCall = captures[beforeRefund];
  check("по списанному платежу ушёл revoke на ту же сумму",
    refundCall?.script === "revoke.php" && Number(refundCall?.pg_refund_amount) === TOTAL,
    JSON.stringify(refundCall || {}));
  const afterRefund = await readOrder("PAY_GATE");
  check("деньги возвращены", afterRefund.payment?.status === "refunded",
    afterRefund.payment?.status);
  check("сумма возврата записана", afterRefund.payment?.refundedAmount === TOTAL);

  // ---- контрольное взвешивание двигает деньги -----------------------------------------------------
  // Списали по заявленному весу, а на весах оказалось меньше. Уведомление покупателю обещает
  // «Возврат N ₸» — и раньше за этим обещанием ничего не следовало. Теперь следует: разница
  // уходит обратно на карту тем же revoke, а заказ остаётся оплаченным, потому что вернули часть.
  const fileOf = (orderId, name, kind) => ({
    kind, name,
    url: "http://127.0.0.1:9199/v0/b/demo-et.appspot.com/o/"
      + encodeURIComponent(`orders/pay_farm/${orderId}/${name}`) + "?alt=media&token=t",
  });
  const weighBatch = db.batch();
  for (const id of ["PAY_WEIGH_DOWN", "PAY_WEIGH_UP"]) {
    weighBatch.set(db.doc("orders/" + id), order(id, {
      pricePerKg: 3500,
      payment: {
        ...order("x").payment, status: "authorized", provider: "freedompay",
        providerPaymentId: id === "PAY_WEIGH_DOWN" ? "70030" : "70031",
        authorizedAt: Timestamp.now(), authorizedAmount: TOTAL,
      },
    }));
  }
  await weighBatch.commit();

  const road = async (id, weightKg) => {
    await call("updateOrderStatus", farmer, { orderId: id, action: "accept" });
    await call("updateOrderStatus", farmer, {
      orderId: id, action: "identify", files: [fileOf(id, "animal.jpg", "photo")],
    });
    return call("updateOrderStatus", farmer, {
      orderId: id, action: "meat_ready",
      files: [fileOf(id, "meat.jpg", "photo")],
      documents: [fileOf(id, "vet.pdf", "doc")],
      scalePhoto: fileOf(id, "scale.jpg", "photo"),
      weightKg,
    });
  };

  const beforeWeigh = captures.length;
  // 60 кг вместо заявленных 65: мясо 210 000 против 227 500, разница −17 500.
  const down = await road("PAY_WEIGH_DOWN", 60);
  check("недовес принят", down.result?.status === "meat_ready",
    JSON.stringify(down.error || down.result));
  const weighed = await readOrder("PAY_WEIGH_DOWN");
  check("пересчёт записан", weighed.weighing?.total === 210000
    && weighed.weighing?.difference === -17500, JSON.stringify(weighed.weighing || {}));
  const back = captures.slice(beforeWeigh)
    .find((c) => c.pg_payment_id === "70030" && c.script === "revoke.php");
  check("разница ушла возвратом на карту",
    back?.script === "revoke.php" && back?.pg_refund_amount === "17500",
    JSON.stringify(back || {}));
  check("заказ остался оплаченным, а не «возвращён»",
    weighed.payment?.status === "captured_partial"
    && weighed.payment?.refundedAmount === 17500
    && weighed.payment?.capturedAmount === TOTAL,
    JSON.stringify(weighed.payment || {}));
  // Шагов было два, и оба написали покупателю: берём тот, где взвешивание, а не съёмка животного.
  const weighNote = (notes) => notes.find((n) => /Контрольный вес/.test(n.body || ""));
  const downNote = weighNote(await notesFor("pay_buyer", "PAY_WEIGH_DOWN"));
  check("покупателю обещали возврат именно на карту",
    /Возврат 17 500 ₸ придёт на ту же карту/.test(downNote?.body || ""),
    downNote?.body || "");

  // 70 кг вместо 65: заказ подорожал. Взять доплату с того же платежа нельзя — и мы не делаем
  // вид, что взяли: в Freedom не уходит ничего, а покупателю сказано рассчитаться на месте.
  const up = await road("PAY_WEIGH_UP", 70);
  check("перевес принят", up.result?.status === "meat_ready",
    JSON.stringify(up.error || up.result));
  check("по доплате возврата не было — списан только клиринг при принятии",
    captures.filter((c) => c.pg_payment_id === "70031")
      .every((c) => c.script === "do_capture.php"),
    JSON.stringify(captures.filter((c) => c.pg_payment_id === "70031").map((c) => c.script)));
  const upOrder = await readOrder("PAY_WEIGH_UP");
  check("по перевесу заказ остался полностью оплаченным",
    upOrder.payment?.status === "captured_full" && !upOrder.payment?.refundedAmount,
    JSON.stringify(upOrder.payment || {}));
  const upNote = weighNote(await notesFor("pay_buyer", "PAY_WEIGH_UP"));
  check("покупателю сказали, как доплатить",
    /Доплата 17 500 ₸ — рассчитайтесь с хозяйством при получении/.test(upNote?.body || ""),
    upNote?.body || "");

  // ---- расписание: брошенные заказы --------------------------------------------------------------
  // Бездействие здесь не безопасно: неклиренный холд Freedom спишет сам на пятые сутки, а
  // неоплаченный заказ всё это время держит доли в лоте. Поэтому проверяется и то, что просроченное
  // закрывается, и то, что свежее остаётся нетронутым.
  const daysAgo = (n) => Timestamp.fromMillis(Date.now() - n * 24 * 3600 * 1000);
  const staleBatch = db.batch();
  staleBatch.set(db.doc("lots/PAY_STALE_LOT"), { ...lot, bookedShares: 2, status: "fully_booked" });
  staleBatch.set(db.doc("orders/PAY_STALE_HOLD"), order("PAY_STALE_HOLD", {
    lotId: "PAY_STALE_LOT", shares: 1, createdAt: daysAgo(5),
    payment: {
      ...order("x").payment, status: "authorized", provider: "freedompay",
      providerPaymentId: "70020", authorizedAt: daysAgo(5), authorizedAmount: TOTAL,
    },
  }));
  staleBatch.set(db.doc("orders/PAY_STALE_UNPAID"), order("PAY_STALE_UNPAID", {
    lotId: "PAY_STALE_LOT", shares: 1, createdAt: daysAgo(3),
  }));
  staleBatch.set(db.doc("orders/PAY_FRESH"), order("PAY_FRESH", {
    lotId: "PAY_STALE_LOT", shares: 1, createdAt: Timestamp.now(),
  }));
  await staleBatch.commit();

  const beforeStale = captures.length;
  // Расписание эмулятор по адресу функции не отдаёт: внутри оно живёт как pubsub-обработчик.
  // Дёргаем его тем же служебным маршрутом, которым эмулятор сам доставляет события.
  const sweep = await fetch(
    "http://127.0.0.1:5001/functions/projects/demo-et/triggers/europe-west3-releaseStaleOrders-0",
    { method: "POST", headers: { "content-type": "application/json" }, body: "{}" },
  );
  check("расписание отработало", sweep.status === 200, String(sweep.status));

  const staleHold = await readOrder("PAY_STALE_HOLD");
  check("просроченный холд закрыт", staleHold.status === "cancelled"
    && staleHold.payment?.status === "cancelled",
    `${staleHold.status} / ${staleHold.payment?.status}`);
  const releaseCall = captures[beforeStale];
  check("по просроченному холду ушёл cancel в Freedom",
    releaseCall?.script === "cancel.php" && releaseCall?.pg_payment_id === "70020",
    JSON.stringify(releaseCall || {}));

  const staleUnpaid = await readOrder("PAY_STALE_UNPAID");
  check("брошенный неоплаченный заказ закрыт", staleUnpaid.status === "cancelled"
    && staleUnpaid.payment?.status === "expired",
    `${staleUnpaid.status} / ${staleUnpaid.payment?.status}`);

  const fresh = await readOrder("PAY_FRESH");
  check("свежий заказ не тронут", fresh.status === "created"
    && fresh.payment?.status === "awaiting", fresh.status);

  const holdNotes = await notesFor("pay_buyer", "PAY_STALE_HOLD");
  check("покупателя предупредили о снятии блокировки",
    holdNotes.some((n) => n.kind === "order_cancelled" && /блокировка/.test(n.body || "")),
    JSON.stringify(holdNotes.map((n) => n.kind)));
  const unpaidNotes = await notesFor("pay_buyer", "PAY_STALE_UNPAID");
  check("покупатель узнал об отмене неоплаченного",
    unpaidNotes.some((n) => n.kind === "order_cancelled"),
    JSON.stringify(unpaidNotes.map((n) => n.kind)));
  check("по неоплаченному заказу в Freedom ничего не ушло",
    !captures.slice(beforeStale).some((c) => c.pg_order_id === "PAY_STALE_UNPAID"),
    JSON.stringify(captures.slice(beforeStale).map((c) => `${c.script}:${c.pg_order_id || ""}`)));

  const freedLot = (await db.doc("lots/PAY_STALE_LOT").get()).data();
  check("доли вернулись в лот и он снова открыт",
    freedLot.bookedShares === 0 && freedLot.status === "open",
    `${freedLot.bookedShares} / ${freedLot.status}`);

  stub.close();
  const failedCount = results.filter((r) => !r).length;
  console.log(failedCount ? `${failedCount} FAILED` : `all ${results.length} passed`);
  process.exit(failedCount ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
