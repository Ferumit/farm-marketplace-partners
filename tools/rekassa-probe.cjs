// Пробник re:Kassa: гоняет БОЕВОЙ модуль фискализации по тестовой кассе.
//
// Важно, что здесь импортируется functions/rekassa.js, а не своя копия логики: иначе пробник
// проверял бы одно, а в бой уезжало другое. Арифметику чека отдельно проверяет
// tests/functions/rekassa.test.cjs — без сети; здесь мы смотрим, что их API принимает то, что
// мы собрали, и что возврат действительно привязывается к продаже.
//
//   node tools/rekassa-probe.cjs --api-key <ключ> --znm <ЗНМ> --password <пароль кассы>
//   ... --pin 1111 --close-shift     — ещё и закрыть смену в конце
//
// Тестовый сервер, боевой кассы не касается.
const path = require("path");
const { randomUUID } = require("crypto");

const BASE = "https://app-test.rekassa.kz/partner";
const arg = (name) => {
  const i = process.argv.indexOf(`--${name}`);
  return i > -1 ? process.argv[i + 1] : null;
};
const API_KEY = arg("api-key");
const ZNM = arg("znm");
const PASSWORD = arg("password");
const PIN = arg("pin");
const CLOSE_SHIFT = process.argv.includes("--close-shift");

if (!API_KEY || !ZNM || !PASSWORD) {
  console.error(`Пробник фискализации re:Kassa (тестовый сервер).

  node tools/rekassa-probe.cjs --api-key <ключ> --znm <ЗНМ> --password <пароль кассы>

Пароль выдаётся в приложении re:Kassa: Настройки → «Подключить приложение» →
выбрать «ТОО Компания» → «Получить пароль».
Показывается один раз, поэтому сразу сохраните.`);
  process.exit(2);
}

(async () => {
  const rk = await import("file://" + path.join(__dirname, "../functions/rekassa.js").replace(/\\/g, "/"));

  // 1. Вход на чужую кассу нашим ключом интеграции.
  const session = await rk.connect(BASE, API_KEY, { znm: ZNM, password: PASSWORD });
  console.log("── Вход: касса #" + session.crsId);
  console.log(`   БИН/ИИН владельца: ${session.taxPayerId}   ← под ним и выйдет чек`);
  console.log(`   номер ККМ в КГД:   ${session.kgdKkmId}`);
  console.log(`   смена: ${session.shiftOpen ? `№${session.shiftNumber} открыта` : "закрыта"}`
    + (session.shiftExpireTime ? `, истекает ${session.shiftExpireTime}` : ""));

  // 2. Чек продажи — настоящий заказ ET: половина туши с дробным весом, разделка, доставка.
  const order = {
    title: "Казахская белоголовая, торпақ — половина туши",
    weightKg: 107.5,
    pricePerKg: 3500,
    meat: 376250,
    cutting: 30000,
    delivery: 15000,
  };
  const soldAt = new Date();
  const sold = await rk.issue(BASE, session, rk.sellTicket(order, soldAt), randomUUID());
  console.log(`\n── Чек продажи: ${sold.ticketNumber}`);
  console.log(`   ссылка покупателю: ${sold.url}`);
  console.log(`   смена: ${sold.shiftNumber}`);

  // 3. Возврат по недовесу — то, ради чего всё и затевалось. Туша вышла на 7,5 кг легче.
  const backKg = 7.5;
  const back = Math.round(backKg * order.pricePerKg);
  const total = order.meat + order.cutting + order.delivery;
  const returned = await rk.issue(BASE, session, rk.returnTicket({
    amount: back,
    weightKg: backKg,
    pricePerKg: order.pricePerKg,
    parent: { kgdKkmId: session.kgdKkmId, ticketNumber: sold.ticketNumber, total, at: soldAt },
  }, new Date()), randomUUID());
  console.log(`\n── Чек возврата на ${back} ₸: ${returned.ticketNumber}`);
  console.log(`   ссылка покупателю: ${returned.url}`);

  if (CLOSE_SHIFT && PIN) {
    await rk.closeShift(BASE, session, PIN, randomUUID());
    console.log(`\n── Смена №${session.shiftNumber} закрыта`);
  }

  console.log(`\n${"=".repeat(60)}`);
  console.log(`Продажа ${total} ₸ и возврат ${back} ₸ прошли. Проверьте оба чека в re:Kassa.`);
})().catch((e) => { console.error("\nСорвалось:", e.message); process.exit(1); });
