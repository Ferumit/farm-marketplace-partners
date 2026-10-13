// Сборка фискального чека re:Kassa.
//
// Тест чистый: ни эмулятора, ни сети, ни ключей —
//   node tests/functions/rekassa.test.cjs
//
// Проверяем арифметику и форму, а не их API: ошибка здесь не видна глазом и всплывёт налоговым
// расхождением. Самое опасное место — количество, умноженное на тысячу: перепутать масштаб
// значит выбить чек на 107 500 килограммов вместо 107,5.
const path = require("path");

const results = [];
function check(label, ok, detail = "") {
  results.push(ok);
  console.log(`${ok ? "PASS" : "FAIL"}  ${label}${detail ? "  (" + detail + ")" : ""}`);
}

(async () => {
  const rk = await import("file://" + path.join(__dirname, "../../functions/rekassa.js").replace(/\\/g, "/"));

  // --- деньги и количество ---------------------------------------------------------------------
  check("тенге раскладываются на целые и копейки",
    JSON.stringify(rk.money(376250)) === JSON.stringify({ bills: "376250", coins: 0 }));
  check("дробные тенге округляются, копеек в тенге не бывает",
    rk.money(100.6).bills === "101", JSON.stringify(rk.money(100.6)));
  check("количество умножается на тысячу", rk.quantity(1) === 1000);
  check("дробный вес проходит без потери десятых", rk.quantity(107.5) === 107500);
  check("пустое количество не ломает", rk.quantity(undefined) === 0);

  // --- чек продажи -----------------------------------------------------------------------------
  const order = {
    title: "Казахская белоголовая, торпақ — половина туши",
    weightKg: 107.5,
    pricePerKg: 3500,
    meat: 376250,
    cutting: 30000,
    delivery: 15000,
  };
  const sell = rk.sellTicket(order, new Date("2026-10-09T16:03:00"));

  check("операция — продажа", sell.operation === "OPERATION_SELL");
  check("вид деятельности — торговля", sell.domain.type === "DOMAIN_TRADING");
  check("три строки: мясо, разделка, доставка", sell.items.length === 3, `их ${sell.items.length}`);

  const meatLine = sell.items[0].commodity;
  check("мясо идёт килограммами", meatLine.measureUnitCode === "166");
  check("в чеке тот же вес, что видел покупатель", meatLine.quantity === 107500);
  check("цена за килограмм — та же", meatLine.price.bills === "3500");
  check("сумма за мясо сходится: 107,5 × 3500", meatLine.sum.bills === "376250");

  check("разделка отдельной строкой, штукой",
    sell.items[1].commodity.sum.bills === "30000" && sell.items[1].commodity.measureUnitCode === "796");
  check("доставка отдельной строкой", sell.items[2].commodity.sum.bills === "15000");

  const total = 376250 + 30000 + 15000;
  check("итог чека — сумма строк", sell.amounts.total.bills === String(total), sell.amounts.total.bills);
  check("оплата картой на ту же сумму",
    sell.payments[0].type === "PAYMENT_CARD" && sell.payments[0].sum.bills === String(total));

  // --- без разделки и доставки -------------------------------------------------------------------
  const bare = rk.sellTicket({ title: "Конина", weightKg: 90, pricePerKg: 4600, meat: 414000 });
  check("без разделки и доставки — одна строка", bare.items.length === 1);
  check("итог равен стоимости мяса", bare.amounts.total.bills === "414000");

  // --- лот старой модели, без цены за килограмм ---------------------------------------------------
  const legacy = rk.sellTicket({ title: "Доля туши", meat: 63000 });
  check("без цены за кг мясо идёт позицией, а не на вес",
    legacy.items[0].commodity.measureUnitCode === "796" && legacy.items[0].commodity.quantity === 1000);
  check("сумма не теряется", legacy.amounts.total.bills === "63000");

  // --- чек возврата ------------------------------------------------------------------------------
  const ret = rk.returnTicket({
    amount: 26250,
    weightKg: 7.5,
    pricePerKg: 3500,
    parent: { kgdKkmId: "000000000000", ticketNumber: "000000000000", total: 421250, at: new Date("2026-10-09T16:03:00") },
  }, new Date("2026-10-10T09:00:00"));

  check("операция — возврат продажи", ret.operation === "OPERATION_SELL_RETURN");
  check("возврат привязан к исходному чеку", ret.parentTicket.parentTicketNumber === "000000000000");
  check("в привязке есть номер ККМ в КГД", ret.parentTicket.kgdKkmId === "000000000000");
  check("сумма исходного чека передана целиком, а не разницей",
    ret.parentTicket.parentTicketTotal.bills === "421250");
  check("возвращаем разницу по той же цене за килограмм",
    ret.items[0].commodity.quantity === 7500 && ret.items[0].commodity.price.bills === "3500");
  check("сумма возврата сходится: 7,5 × 3500", ret.amounts.total.bills === "26250");
  check("дата возврата — своя, не исходного чека",
    ret.dateTime.date.day === "10" && ret.parentTicket.parentTicketDataTime.date.day === "9");

  // --- длинное название не уронит чек -------------------------------------------------------------
  const long = rk.sellTicket({ title: "х".repeat(400), weightKg: 1, pricePerKg: 100, meat: 100 });
  check("слишком длинное название обрезается", long.items[0].commodity.name.length === 250);

  // --- боевой контур или тестовый ------------------------------------------------------------------
  // Ошибка здесь не падает, а врёт покупателю: тестовый чек подпишется «Фискальный». Поэтому
  // всё, что не ровно боевой хост, обязано считаться тестом — включая мусор и подставной домен.
  check("боевой адрес — не тест", rk.isTestBase("https://app.rekassa.kz/partner") === false);
  check("регистр в адресе не обманывает", rk.isTestBase("HTTPS://APP.REKASSA.KZ/partner") === false);
  check("тестовый адрес — тест", rk.isTestBase("https://app-test.rekassa.kz/partner") === true);
  check("похожий домен — тест", rk.isTestBase("https://app.rekassa.kz.evil.example/x") === true);
  check("боевой хост в логине, а не в адресе — тест",
    rk.isTestBase("https://app.rekassa.kz@app-test.rekassa.kz/partner") === true);
  check("адрес без схемы — тест", rk.isTestBase("app.rekassa.kz") === true);
  check("пусто — тест", rk.isTestBase("") === true && rk.isTestBase(undefined) === true);

  const failed = results.filter((r) => !r).length;
  console.log(`\nre:Kassa: ${results.length - failed} из ${results.length}`);
  process.exit(failed ? 1 : 0);
})();
