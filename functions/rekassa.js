/**
 * Фискальные чеки re:Kassa.
 *
 * Продавец — хозяйство, не платформа: так разъясняет КГД про продажи через электронные площадки,
 * и так решило руководство. Поэтому чек выбивается НЕ нашей кассой, а кассой того хозяйства,
 * чьё мясо продано, и выходит под его БИН.
 *
 * Как это возможно технически: ключ API выдан один раз на всю интеграцию (нам как стороннему
 * приложению), а пароль выдаёт каждая касса отдельно — её владелец, в своём приложении re:Kassa.
 * Мы входим «наш ключ + чужой пароль» и получаем право выбивать чеки на этой кассе. Проверено на
 * тестовой кассе 9 октября: чек вышел под БИН её владельца, а не под нашим.
 *
 * Что здесь намеренно НЕ делается:
 *   - не решаем, выбивать чек или нет. Это знает вызывающий: чек идёт по факту списания денег;
 *   - не ходим в Firestore. Доступ к кассе передают аргументом — модуль остаётся проверяемым;
 *   - не роняем заказ при ошибке. Невыбитый чек — беда, но откат уже списанных денег хуже.
 */

/** Деньги у них разложены на целые и копейки. Тенге дробных не имеет, но формат обязателен. */
export function money(tenge) {
  const n = Math.round(Number(tenge) || 0);
  return { bills: String(n), coins: 0 };
}

/**
 * Количество умножено на тысячу: в их примерах quantity 1000 при цене 2203 даёт сумму 2203.
 * Нам это нужно для дробного веса — туша в 107,5 кг проходит как 107500.
 */
export function quantity(units) {
  return Math.round((Number(units) || 0) * 1000);
}

/** Килограмм по ОКЕИ. Штука — 796; мясо продаём на вес, и в чеке это честнее. */
const UNIT_KG = "166";
const UNIT_PIECE = "796";

function stamp(date) {
  const d = date instanceof Date ? date : new Date();
  return {
    date: { year: String(d.getFullYear()), month: String(d.getMonth() + 1), day: String(d.getDate()) },
    time: { hour: String(d.getHours()), minute: String(d.getMinutes()), second: String(d.getSeconds()) },
  };
}

function commodity({ name, units, unitCode, price, sum }) {
  return {
    type: "ITEM_TYPE_COMMODITY",
    commodity: {
      name: String(name).slice(0, 250),
      sectionCode: "1",
      quantity: quantity(units),
      price: money(price),
      sum: money(sum),
      measureUnitCode: unitCode,
    },
  };
}

/**
 * Строки чека по заказу ET.
 *
 * Мясо идёт килограммами по цене за килограмм — так в чеке видно то же, что покупатель видел на
 * сайте. Разделка и доставка — отдельными строками по одной штуке: это разные услуги, и
 * сворачивать их в «мясо» значит показать в чеке цену за килограмм, которой не было.
 */
export function ticketItems({ title, weightKg, pricePerKg, meat, cutting, delivery }) {
  const items = [];
  if (weightKg > 0 && pricePerKg > 0) {
    items.push(commodity({
      name: title || "Мясо, половина туши",
      units: weightKg,
      unitCode: UNIT_KG,
      price: pricePerKg,
      sum: meat,
    }));
  } else {
    // Лот старой модели: цены за килограмм нет, продаём как позицию.
    items.push(commodity({ name: title || "Мясо", units: 1, unitCode: UNIT_PIECE, price: meat, sum: meat }));
  }
  if (cutting > 0) {
    items.push(commodity({ name: "Разделка", units: 1, unitCode: UNIT_PIECE, price: cutting, sum: cutting }));
  }
  if (delivery > 0) {
    items.push(commodity({ name: "Доставка", units: 1, unitCode: UNIT_PIECE, price: delivery, sum: delivery }));
  }
  return items;
}

/** Тело чека продажи. */
export function sellTicket(order, at) {
  const items = ticketItems(order);
  const total = items.reduce((s, i) => s + Number(i.commodity.sum.bills), 0);
  return {
    operation: "OPERATION_SELL",
    dateTime: stamp(at),
    domain: { type: "DOMAIN_TRADING" },
    items,
    // Оплата всегда картой: наличных платформа не принимает в принципе.
    payments: [{ type: "PAYMENT_CARD", sum: money(total) }],
    amounts: { total: money(total), taken: money(0), change: money(0) },
  };
}

/**
 * Тело чека возврата — перерасчёт после контрольного взвешивания.
 *
 * `parentTicket` привязывает возврат к продаже. Без него это был бы отдельный возврат непонятно
 * за что, и налоговая увидела бы две несвязанные операции вместо одной уточнённой.
 */
export function returnTicket({ amount, weightKg, pricePerKg, parent }, at) {
  const byWeight = weightKg > 0 && pricePerKg > 0;
  const item = commodity({
    name: "Перерасчёт после контрольного взвешивания",
    units: byWeight ? weightKg : 1,
    unitCode: byWeight ? UNIT_KG : UNIT_PIECE,
    price: byWeight ? pricePerKg : amount,
    sum: amount,
  });
  return {
    operation: "OPERATION_SELL_RETURN",
    dateTime: stamp(at),
    domain: { type: "DOMAIN_TRADING" },
    items: [item],
    payments: [{ type: "PAYMENT_CARD", sum: money(amount) }],
    amounts: { total: money(amount), taken: money(0), change: money(0) },
    parentTicket: {
      kgdKkmId: String(parent.kgdKkmId || ""),
      parentTicketNumber: String(parent.ticketNumber || ""),
      parentTicketTotal: money(parent.total),
      parentTicketDataTime: stamp(parent.at),
      parentTicketIsOffline: false,
    },
  };
}

/**
 * Тестовый контур re:Kassa или боевой.
 *
 * Чек с тестового сервера выглядит как настоящий — те же поля, тот же вид, своя ссылка. Но в
 * налоговую он не уходит, и покупателю выдавать его за фискальный документ нельзя. Решает это
 * адрес, а не отдельная настройка: адрес — единственное, что знает правду, и переключить его,
 * забыв про флаг, невозможно.
 *
 * Всё, что не боевой хост, считается тестом намеренно. Ошибиться можно в две стороны, и они
 * неравны: назвать настоящий чек тестовым — досадная неточность, назвать тестовый настоящим —
 * обман покупателя.
 */
export function isTestBase(base) {
  try {
    return new URL(String(base).trim()).hostname.toLowerCase() !== "app.rekassa.kz";
  } catch {
    // Не разобрали адрес — значит боевым его назвать не можем. На таком и чек не выбьется.
    return true;
  }
}

/** Один запрос к их API. X-Request-ID отсекает повтор при обрыве связи — второй чек не выйдет. */
async function call(base, path, { method = "POST", token, body, requestId, headers = {} } = {}) {
  const res = await fetch(`${base}${path}`, {
    method,
    headers: {
      "content-type": "application/json",
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...(requestId ? { "X-Request-ID": requestId } : {}),
      ...headers,
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  const text = await res.text();
  let json = null;
  try { json = JSON.parse(text); } catch { /* пусто или не json */ }
  if (!res.ok) {
    const why = json?.text || json?.message || text.slice(0, 200) || `HTTP ${res.status}`;
    throw new Error(`re:Kassa ${path}: ${why}`);
  }
  return json;
}

/**
 * Вход на кассу хозяйства. Возвращает токен и внутренний идентификатор кассы, а заодно её номер
 * в КГД — он нужен для возврата и лежит на кассе, а не на чеке.
 */
export async function connect(base, apiKey, { znm, password }) {
  const auth = await call(base, `/api/auth/login?apiKey=${encodeURIComponent(apiKey)}&format=json`, {
    body: { number: znm, password },
  });
  const crsId = auth.id;
  const crs = await call(base, `/api/crs/${crsId}`, { method: "GET", token: auth.token });
  return {
    token: auth.token,
    crsId,
    kgdKkmId: String(crs.registrationNumber || crs?.data?.service?.regInfo?.kkm?.fnsKkmId || ""),
    taxPayerId: String(crs?.data?.service?.regInfo?.org?.inn || ""),
    shiftNumber: crs.shiftNumber,
    shiftOpen: !!crs.shiftOpen,
    shiftExpireTime: crs.shiftExpireTime || null,
  };
}

/** Выбивает чек и возвращает то, что нужно сохранить: номер, ссылку покупателю и смену. */
export async function issue(base, session, ticket, requestId) {
  const t = await call(base, `/api/crs/${session.crsId}/tickets`, {
    token: session.token, body: ticket, requestId,
  });
  return {
    ticketNumber: String(t.ticketNumber || ""),
    ticketId: t.id ?? null,
    // Ссылка на чек у ОФД — её и показываем покупателю.
    url: t.fdoQrCode || t.qrCode || null,
    shiftNumber: t.shiftNumber ?? null,
    kgdKkmId: session.kgdKkmId,
  };
}

/**
 * Закрывает смену. Смена открывается сама при первом чеке и живёт сутки, так что закрывать её
 * надо по расписанию, иначе касса встанет на `Shift period expired`.
 *
 * ПИН кассы — отдельный секрет от пароля интеграции: войти одним, закрыть смену другим.
 */
export async function closeShift(base, session, pin, requestId) {
  return call(base, `/api/crs/${session.crsId}/shifts/${session.shiftNumber}/close`, {
    token: session.token,
    requestId,
    headers: { "cash-register-password": String(pin) },
  });
}
