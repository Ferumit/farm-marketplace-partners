// Подпись Freedom Pay.
//
// Тест чистый: ни эмулятора, ни сети, ни ключей. Запускается сам по себе —
//   node tests/functions/freedompay.test.cjs
// и должен пройти ДО первого запроса наружу. Смысл именно в этом: подпись — то место, где
// ошибка не видна глазом, а проявляется либо неработающей оплатой, либо принятым чужим вебхуком.
//
// Эталон — Platron PG_Signature.php, от которого происходит Freedom Pay. Строки в тестах ниже
// посчитаны по его логике вручную, а не сняты с нашей же реализации: снимок собственного
// поведения не проверяет ничего.

const path = require("path");

const results = [];
function check(label, ok, detail = "") {
  results.push(ok);
  console.log(`${ok ? "PASS" : "FAIL"}  ${label}${detail ? "  (" + detail + ")" : ""}`);
}

(async () => {
  const fp = await import("file://" + path.join(__dirname, "../../functions/freedompay.js").replace(/\\/g, "/"));
  const KEY = "secret_key";

  // --- строка подписи из документации ----------------------------------------------------------
  // Документация Freedom Pay показывает ровно этот пример:
  //   init_payment.php;25;Order;123;random;secret_key
  // Порядок значений — по алфавиту ИМЁН: pg_amount, pg_description, pg_merchant_id, pg_salt.
  const docExample = fp.signatureString("init_payment.php", {
    pg_merchant_id: 123,
    pg_amount: 25,
    pg_description: "Order",
    pg_salt: "random",
  }, KEY);
  check("строка из примера документации", docExample === "init_payment.php;25;Order;123;random;secret_key", docExample);

  // --- порядок вставки не влияет на подпись ----------------------------------------------------
  const a = fp.sign("init_payment.php", { pg_amount: 25, pg_salt: "s", pg_merchant_id: 1 }, KEY);
  const b = fp.sign("init_payment.php", { pg_merchant_id: 1, pg_amount: 25, pg_salt: "s" }, KEY);
  check("порядок ключей не меняет подпись", a === b);

  // --- pg_sig в подпись не входит --------------------------------------------------------------
  const withoutSig = fp.sign("init_payment.php", { pg_amount: 25, pg_salt: "s" }, KEY);
  const withSig = fp.sign("init_payment.php", { pg_amount: 25, pg_salt: "s", pg_sig: "деsomething" }, KEY);
  check("pg_sig не участвует в подписи", withoutSig === withSig);

  // --- счётчик увеличивается и на пропущенном pg_sig --------------------------------------------
  // Если бы пропуск сдвигал нумерацию, эти две подписи разошлись бы. В эталоне $i++ стоит ДО
  // проверки на pg_sig, и этот тест держит перенос честным.
  const skipFirst = fp.signatureString("x.php", { pg_sig: "zz", pg_b: 2, pg_a: 1 }, KEY);
  check("пропуск pg_sig не сдвигает нумерацию", skipFirst === "x.php;1;2;secret_key", skipFirst);

  // --- вложенные позиции чека -------------------------------------------------------------------
  // pg_receipt_positions001 → элементы получают 001, 002 вместо родительского счётчика,
  // внутри каждого — своё имя с номером. Значения идут по алфавиту плоских имён:
  //   pg_amount001                              -> 100
  //   pg_receipt_positions001count001           -> 1
  //   pg_receipt_positions001name002            -> Половина туши
  //   pg_receipt_positions002count001           -> 2
  //   pg_receipt_positions002name002            -> Разделка
  const receipt = fp.signatureString("init_payment.php", {
    pg_amount: 100,
    pg_receipt_positions: [
      { count: 1, name: "Половина туши" },
      { count: 2, name: "Разделка" },
    ],
  }, KEY);
  check(
    "вложенные позиции чека",
    receipt === "init_payment.php;100;1;Половина туши;2;Разделка;secret_key",
    receipt,
  );

  // --- приведение значений ----------------------------------------------------------------------
  const casts = fp.signatureString("x.php", { pg_a: null, pg_b: false, pg_c: true, pg_d: 0 }, KEY);
  check("null и false — пустая строка, true — единица", casts === "x.php;;;1;0;secret_key", casts);

  // --- проверка чужой подписи --------------------------------------------------------------------
  const params = { pg_order_id: "ord-1", pg_amount: 227500, pg_salt: "abc" };
  const signedParams = fp.signed("result.php", params, KEY);
  check("свою подпись принимаем", fp.verify("result.php", signedParams, KEY));
  check("чужой ключ отвергаем", !fp.verify("result.php", signedParams, "другой_ключ"));
  check("подменённую сумму отвергаем",
    !fp.verify("result.php", { ...signedParams, pg_amount: 1 }, KEY));
  check("другое имя скрипта отвергаем", !fp.verify("other.php", signedParams, KEY));
  check("пустую подпись отвергаем", !fp.verify("result.php", { ...params, pg_sig: "" }, KEY));
  check("короткую подпись отвергаем", !fp.verify("result.php", { ...params, pg_sig: "abc" }, KEY));
  check("подпись без pg_sig отвергаем", !fp.verify("result.php", params, KEY));

  // --- соль ---------------------------------------------------------------------------------------
  const salts = new Set(Array.from({ length: 200 }, () => fp.salt()));
  check("соль каждый раз новая", salts.size === 200);
  check("соль — только латиница и цифры", [...salts].every((s) => /^[A-Za-z0-9]{16}$/.test(s)));
  check("signed сам ставит соль", typeof fp.signed("x.php", { pg_a: 1 }, KEY).pg_salt === "string");
  check("signed не затирает заданную соль",
    fp.signed("x.php", { pg_a: 1, pg_salt: "мой" }, KEY).pg_salt === "мой");

  // --- точка с запятой внутри значения -----------------------------------------------------------
  // Протокол ничего не экранирует, поэтому два разных набора могут дать одну строку. Это не наш
  // баг и чинить его нельзя — но знать про него надо, иначе однажды это спишут на «магию».
  const collideA = fp.signatureString("x.php", { pg_a: "1;2", pg_b: "3" }, KEY);
  const collideB = fp.signatureString("x.php", { pg_a: "1", pg_b: "2;3" }, KEY);
  check("известное свойство протокола: ; внутри значения неотличим от разделителя",
    collideA === collideB, collideA);

  // --- имя скрипта из адреса ----------------------------------------------------------------------
  check("имя скрипта из их адреса",
    fp.scriptNameOf("https://api.freedompay.kz/init_payment.php") === "init_payment.php");
  check("имя скрипта из нашего адреса",
    fp.scriptNameOf("https://europe-west3-et.cloudfunctions.net/freedompayResult") === "freedompayResult");
  check("адрес с параметрами",
    fp.scriptNameOf("https://api.freedompay.kz/do_capture.php?x=1") === "do_capture.php");
  check("адрес, кончающийся слэшем, имени не даёт", fp.scriptNameOf("https://example.kz/pay/") === "");

  // --- ответ на уведомление -------------------------------------------------------------------------
  const xml = fp.replyXml("freedompayResult", "ok", "Заказ оплачен", KEY);
  const parsed = fp.parseXml(xml);
  check("ответ — валидный XML с нужными полями",
    xml.startsWith('<?xml version="1.0" encoding="utf-8"?>')
    && parsed.pg_status === "ok" && parsed.pg_description === "Заказ оплачен"
    && /^[0-9a-f]{32}$/.test(parsed.pg_sig || ""));
  check("наш ответ проходит нашу же проверку", fp.verify("freedompayResult", parsed, KEY));

  // --- разбор их ответа ------------------------------------------------------------------------------
  const theirs = fp.parseXml(`<?xml version="1.0"?><response>
    <pg_status>ok</pg_status><pg_payment_id>987</pg_payment_id>
    <pg_redirect_url>https://api.freedompay.kz/pay.html?x=1&amp;y=2</pg_redirect_url>
    <pg_salt>zz</pg_salt><pg_sig>0123456789abcdef0123456789abcdef</pg_sig></response>`);
  check("разбор их ответа",
    theirs.pg_status === "ok" && theirs.pg_payment_id === "987"
    && theirs.pg_redirect_url === "https://api.freedompay.kz/pay.html?x=1&y=2",
    JSON.stringify(theirs));

  const failed = results.filter((r) => !r).length;
  console.log(failed ? `${failed} FAILED` : `all ${results.length} passed`);
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
