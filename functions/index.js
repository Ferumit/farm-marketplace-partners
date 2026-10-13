import { setGlobalOptions } from "firebase-functions/v2";
import { onCall, onRequest, HttpsError } from "firebase-functions/v2/https";
import { defineSecret } from "firebase-functions/params";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { onDocumentCreated } from "firebase-functions/v2/firestore";
import { initializeApp } from "firebase-admin/app";
import { getFirestore, FieldValue, Timestamp } from "firebase-admin/firestore";
import { getAuth } from "firebase-admin/auth";
import { getMessaging } from "firebase-admin/messaging";
import { signed, verify, parseXml, parseCallbackBody, replyXml } from "./freedompay.js";

// Same region as Firestore (europe-west3 per firebase.json) so a transaction isn't paying for
// a cross-region round trip on every read and write.
setGlobalOptions({ region: "europe-west3", maxInstances: 10 });

// invoker: public lets Cloud Run pass the HTTP request through to the function at all; it is
// NOT authorization. Every callable still checks request.auth and, for staff, the role and the
// staff record. Without it each new callable deploys as "Require authentication" and answers
// 403 until someone flips it by hand in the Cloud Run console - which is what happened to
// createOrder and updateOrderStatus.
//
// Оно стоит ЗДЕСЬ, а не в setGlobalOptions, намеренно: глобальная настройка открывала и
// триггеры. Событийная функция не должна принимать запросы из интернета вообще - вызывает её
// Eventarc, а не человек; открытая, она принимает поддельное событие и делает по нему работу.
const CALLABLE = { invoker: "public" };

// Секрет Freedom Pay. Объявлен здесь, а не в платёжном разделе ниже: его просят и те функции,
// которые стоят в файле раньше (updateOrderStatus списывает холд при принятии заказа), а const
// до своего определения недоступен.
const PAY_SECRET = defineSecret("FREEDOMPAY_SECRET_PAY");
// Ключ интеграции re:Kassa. Один на всю платформу: касс много, по одной на хозяйство, а ключ
// опознаёт НАС как стороннее приложение. Пароль каждой кассы хранится у её хозяйства.
const REKASSA_KEY = defineSecret("REKASSA_API_KEY");

initializeApp();
const db = getFirestore();

const MAX_SHARES_PER_ORDER = 100;

// Farm statuses that may sell - the same list the website uses to decide what buyers see.
// `pending_review` and `rejected` farms can prepare lots but not take orders.
const SELLING_PARTNER_STATUSES = ["verified", "active"];

// ---------------------------------------------------------------------------------------------
// Money
//
// Every amount here is an INTEGER NUMBER OF TENGE. Not tiyn, not a float. The existing data is
// already in this shape (pricePerShare: 110500 means 110 500 ₸), and a silent switch to minor
// units is the classic way to ship an order that costs a hundred times too much - so the
// convention is stated once and every new money field follows it. `currency` is written onto
// every order so a second currency cannot be introduced by accident later.
// ---------------------------------------------------------------------------------------------
const CURRENCY = "KZT";

// Where an order stops moving. The apps mirror this in et_core's isFinished.
const FINISHED_STATUSES = ["completed", "cancelled"];

// Commission from the ТЗ: 10% total, split 5% platform / 3% acquiring / 2% arbitration fund.
// Only the RATES are stamped onto the order at creation; the actual amount is computed when
// money is really captured, because an order can be captured partially or refunded. Storing the
// rates on the order (instead of looking them up later) means a rate change never rewrites
// history for orders that were already agreed.
const COMMISSION_RATES = { totalPct: 10, platformPct: 5, acquiringPct: 3, arbitrationPct: 2 };

// ---------------------------------------------------------------------------------------------
// Payment switch
//
// Freedom Pay подключён, но включать онлайн-оплату СРАЗУ ВСЕМ нельзя: на example.kz идёт живой
// пилот, где покупатель и фермер рассчитываются между собой напрямую. Глобальный рубильник
// означал бы, что настоящий покупатель настоящего хозяйства вдруг упирается в платёжную
// страницу, которой вчера не было.
//
// Поэтому оплата включается ПОИМЁННО. Заказы перечисленных покупателей создаются со статусом
// `awaiting` и требуют оплаты; у всех остальных — `not_required`, и всё работает ровно как
// раньше. Список живёт в окружении (functions/.env), то есть меняется деплоем, а не кликом в
// консоли: он решает, с кого брать деньги, и это заслуживает релиза.
//
// Решение записывается НА ЗАКАЗ в момент создания. Значит, убрав человека из списка завтра, мы
// не меняем правила для заказа, который он сделал сегодня, — а это ровно та ошибка, из-за
// которой оплаченный заказ однажды оказался бы «не требующим оплаты».
// ---------------------------------------------------------------------------------------------
const PAYING_BUYERS = new Set(
  String(process.env.ET_PAYING_BUYERS || "").split(",").map((s) => s.trim()).filter(Boolean),
);

// Вторая ось: хозяйства, у которых онлайн платят ВСЕ покупатели. Поимённый список работает,
// пока покупатель один и известен заранее; на показе заранее не известен никто — люди
// регистрируются при тебе. Поэтому платит тот, кто заказывает у демо-хозяйства, кем бы он ни был.
//
// Почему не «все платят всегда»: мерчант в тестовом режиме, и настоящая карта на его странице не
// пройдёт. Включить оплату для всех — значит оставить каждого живого покупателя с заказом,
// который нечем оплатить и который хозяйство не может взять в работу.
const PAYING_PARTNERS = new Set(
  String(process.env.ET_PAYING_PARTNERS || "").split(",").map((s) => s.trim()).filter(Boolean),
);

// В эмуляторе платят все: вести поимённый список ради тестов было бы издевательством.
const PAY_EVERYONE = process.env.FUNCTIONS_EMULATOR === "true" && process.env.ET_PAYMENTS === "on";

/**
 * Платит ли этот заказ онлайн.
 *
 * Совместная покупка платит так же, как заказ на одного: всю сумму вносит организатор, доли с
 * участников он собирает сам. Выбор сознательный. Честные N холдов на один заказ потребовали бы
 * отдельного платежа на каждого участника, нового состояния «оплатили не все», отката брони и
 * дележа перерасчёта после взвешивания — целого денежного тракта ради механики, которой пока
 * никто не пользовался. А так не появляется ни одной новой денежной ветки: холд, списание,
 * возврат и чек идут теми же путями, что проверены на обычном заказе.
 */
function buyerPaysOnline(buyerUid, { partnerId = "" } = {}) {
  // `*` — платят у ЛЮБОГО хозяйства, включая то, которое зарегистрируют через минуту. Нужно
  // ровно там, где список по именам не успевает: на показе хозяйство заводят при зрителях, и
  // деплой ради одного uid пришлось бы делать у них на глазах. Убирается одной строкой в .env,
  // и первое же настоящее хозяйство — повод её убрать.
  return PAY_EVERYONE
    || PAYING_BUYERS.has(String(buyerUid || ""))
    || PAYING_PARTNERS.has("*")
    || PAYING_PARTNERS.has(String(partnerId || ""));
}

// The payment lifecycle, kept strictly separate from the fulfilment lifecycle further down. Two
// axes, because they are genuinely independent: money can be refunded on a delivered order, and
// a fully paid order can still be sitting unconfirmed by the farmer.
//
//   awaiting -> authorized -> captured_partial -> captured_full
//   any      -> failed | expired
//   captured_* -> refund_pending -> refunded
//
// `not_required` is the pilot state: no money flows through the platform for this order at all.
const PAYMENT_SETTLED = ["authorized", "captured_partial", "captured_full"];

/**
 * True when the payment state permits the farmer to start work on the order.
 *
 * Глобального флага здесь больше нет и быть не должно: `not_required` на самом заказе и означает
 * «через нас деньги по нему не идут». Читать настройку вместо того, что записано на заказе, —
 * это и есть способ однажды пустить в работу неоплаченный заказ.
 */
function paymentClearsFulfilment(payment) {
  const status = payment?.status;
  return status === "not_required" || PAYMENT_SETTLED.includes(status);
}

/** The payment block stamped onto a brand-new order. */
function initialPayment(buyerUid, options) {
  return {
    status: buyerPaysOnline(buyerUid, options) ? "awaiting" : "not_required",
    provider: null,
    providerOrderId: null,
    method: null,
    authorizedAmount: 0,
    capturedAmount: 0,
    refundedAmount: 0,
    authorizedAt: null,
    capturedAt: null,
    refundedAt: null,
  };
}

// Russian needs three forms. The site already gets this right in data.js; this function was the
// last place telling a buyer "Свободно только 2 долей".
function pluralRu(n, one, few, many) {
  const mod10 = n % 10;
  const mod100 = n % 100;
  if (mod10 === 1 && mod100 !== 11) return one;
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) return few;
  return many;
}

function requireRealUser(auth) {
  if (!auth) throw new HttpsError("unauthenticated", "Нужно войти в аккаунт.");
  // Anonymous sessions are what the public catalogue browses with - they must not act.
  if (auth.token?.firebase?.sign_in_provider === "anonymous") {
    throw new HttpsError("permission-denied", "Подтвердите номер телефона.");
  }
  return auth.uid;
}

// =============================================================================================
// Notifications
//
// One document per event in `notifications`, addressed to the person it concerns and written only
// here - inside the SAME transaction as the event itself, so a notification can never claim
// something that did not happen, and never goes missing when it did. A client may mark its own
// read and nothing else (firestore.rules): anything a browser could write, a browser could forge,
// and "хозяйство приняло заказ" is not a sentence a stranger may put in front of a buyer.
//
// The site shows them in the header; the apps have FCM push of their own. Email is the same
// notification handed to the Firebase "Trigger Email" extension, which is not installed yet -
// MAIL_ENABLED is the one line to flip once it is, because a `mail` collection nobody delivers is
// just a pile of unsent letters.
// =============================================================================================
const MAIL_ENABLED = false;

const tenge = (n) => String(Math.round(Number(n) || 0)).replace(/\B(?=(\d{3})+(?!\d))/g, " ") + " ₸";
const FORMAT_LABEL = { half: "Половина туши", whole: "Целая туша" };
/** HH:MM in Almaty (UTC+5) - what both parties' clocks show. */
const atTime = (ts) => new Date(ts.toMillis() + 5 * 3600 * 1000).toISOString().slice(11, 16);

/**
 * Writes one collected notification. Call sites gather them into an array during the transaction
 * and write them at the end of it; a retried transaction clears that array first, so nothing is
 * written - or emailed - twice.
 */
function notify(tx, n) {
  tx.set(db.collection("notifications").doc(), {
    uid: String(n.to.uid),
    role: n.to.role || null,
    kind: n.kind,
    title: String(n.title).slice(0, 120),
    body: String(n.body || "").slice(0, 400),
    link: n.link || null,
    orderId: n.orderId || null,
    groupId: n.groupId || null,
    read: false,
    createdAt: Timestamp.now(),
  });
}

/**
 * Push. One notification document, one push to every phone that person signed into.
 *
 * A trigger rather than a call inside each transaction, on purpose: the notification is the
 * record, the push is only a knock on the door. A failed send must never roll back an accepted
 * order, and every path that writes a notification - now and later - gets push for free.
 *
 * Tokens live beside the person (clients/{uid}/devices or partners/{uid}/devices, id = token).
 * A token Firebase says is dead is deleted here: nobody else ever will, and stale tokens are how
 * a phone that changed hands starts receiving someone else's orders.
 */
export const pushNotification = onDocumentCreated("notifications/{notificationId}", async (event) => {
  // Событию не верим: читаем уведомление заново по его id и им же пользуемся. Полезная нагрузка
  // события приходит снаружи процесса, и если её взять на веру, то подделанное событие само
  // назначит и текст push'а, и адресата, и документ, в который мы потом запишем результат.
  // Firestore - наш источник правды; событие лишь повод в него заглянуть.
  const ref = db.collection("notifications").doc(event.params.notificationId);
  const snap = await ref.get();
  if (!snap.exists) return;
  const note = snap.data();
  if (!note || !note.uid) return;

  const owner = note.role === "partner" ? "partners" : "clients";
  const devices = await db.collection(owner).doc(String(note.uid)).collection("devices").get();
  const tokens = devices.docs.map((d) => d.id).filter((t) => typeof t === "string" && t.length > 20);

  if (!tokens.length) {
    // Nothing to knock on. Recorded so "почему не пришло уведомление" has an answer.
    await ref.set({ push: { state: "no_devices", at: Timestamp.now() } }, { merge: true });
    return;
  }

  const message = {
    notification: { title: String(note.title || "ET"), body: String(note.body || "") },
    data: {
      notificationId: event.params.notificationId,
      kind: String(note.kind || ""),
      orderId: String(note.orderId || ""),
      groupId: String(note.groupId || ""),
      link: String(note.link || ""),
    },
    android: {
      priority: "high",
      // No channelId: a message naming a channel the app never created is dropped by Android.
      // The SDK falls back to the app default channel, which it creates itself if need be.
      notification: { sound: "default" },
    },
    apns: { payload: { aps: { sound: "default" } } },
  };

  let sent = 0;
  const dead = [];
  try {
    const result = await getMessaging().sendEachForMulticast({ ...message, tokens });
    sent = result.successCount;
    result.responses.forEach((response, i) => {
      const code = response.error?.code || "";
      if (code === "messaging/registration-token-not-registered" || code === "messaging/invalid-argument") {
        dead.push(tokens[i]);
      }
    });
  } catch (e) {
    // No FCM credentials (the emulator) or a transport failure. The notification itself stands.
    await ref.set(
      { push: { state: "failed", error: String(e?.message || e).slice(0, 200), at: Timestamp.now() } },
      { merge: true },
    );
    return;
  }

  if (dead.length) {
    const batch = db.batch();
    for (const token of dead) {
      batch.delete(db.collection(owner).doc(String(note.uid)).collection("devices").doc(token));
    }
    await batch.commit().catch(() => {});
  }

  await ref.set(
    {
      push: {
        state: sent ? "sent" : "failed",
        sent,
        devices: tokens.length,
        dropped: dead.length,
        at: Timestamp.now(),
      },
    },
    { merge: true },
  );
});

/** The address this person asked us to write to, or null. Farms keep it private; buyers too. */
async function emailOf(to) {
  try {
    const snap = to.role === "partner"
      ? await db.collection("partners").doc(String(to.uid)).collection("private").doc("contact").get()
      : await db.collection("clients").doc(String(to.uid)).get();
    const email = snap.exists ? snap.data().email : null;
    return typeof email === "string" && email.includes("@") ? email : null;
  } catch (e) {
    return null;
  }
}

/**
 * Queues the letters for notifications already written. Runs AFTER the transaction commits and
 * never throws into the caller: a failed letter must not undo an accepted order.
 */
async function queueEmails(notes) {
  if (!MAIL_ENABLED || !notes.length) return;
  try {
    const addresses = await Promise.all(notes.map((n) => emailOf(n.to)));
    const batch = db.batch();
    let any = false;
    notes.forEach((n, i) => {
      if (!addresses[i]) return;
      any = true;
      batch.set(db.collection("mail").doc(), {
        to: addresses[i],
        message: {
          subject: n.title,
          text: `${n.body}\n\n${n.link ? "https://example.kz" + n.link : "https://example.kz"}`,
        },
        createdAt: Timestamp.now(),
      });
    });
    if (any) await batch.commit();
  } catch (e) {
    console.error("email queue failed", e);
  }
}

// ---------------------------------------------------------------------------------------------
// Formats and prices
//
// A lot is one carcass. It sells in halves or whole: totalShares 2 means two halves (a half is one
// share, the whole carcass both), totalShares 1 means whole only. Quarters would be totalShares 4
// with the same arithmetic - which is why a format is counted in shares rather than kept as a list.
//
// Meat is priced per kilogram of carcass on the lot's approximate weight; the real weight comes at
// the control weighing after slaughter and the difference is settled then. The farm's own paid
// cutting is priced per HALF carcass (a whole costs twice), delivery per order at the farm's tariff
// for the chosen city - or pickup. Every amount is computed here from the lot and the farm's
// storefront; nothing the browser sends is taken as a price.
// ---------------------------------------------------------------------------------------------
const FORMATS = ["half", "whole"];
const DELIVERY_SLOTS = ["morning", "day", "evening", "any"];
const MAX_DELIVERY_DAYS_AHEAD = 120;

const money = (n) => Math.max(0, Math.round(Number(n) || 0));

/** How many of the lot's shares a format takes, or 0 when the lot cannot be sold that way. */
function sharesFor(lot, format) {
  const total = Number(lot.totalShares) || 0;
  if (format === "whole") return total;
  if (format === "half") return total >= 2 && total % 2 === 0 ? total / 2 : 0;
  return 0;
}

function priceOrder({ lot, storefront, format, shares, cuttingId, deliveryId }) {
  const total = Number(lot.totalShares) || 0;
  const fraction = shares / total;
  const pricePerKg = money(lot.pricePerKg);
  const weight = Number(lot.totalWeight) || 0;

  let meat;
  let estimatedWeightKg = null;
  if (pricePerKg > 0 && weight > 0) {
    estimatedWeightKg = Math.round(weight * fraction * 10) / 10;
    meat = Math.round(pricePerKg * weight * fraction);
  } else {
    meat = money(lot.pricePerShare) * shares; // lots from before prices per kilogram
  }

  const halves = format === "whole" ? 2 : 1;
  let cutting = null;
  if (cuttingId) {
    const option = (storefront?.cutting || []).find((c) => c && c.id === cuttingId);
    if (!option) throw new HttpsError("failed-precondition", "Такой разделки у хозяйства больше нет — выберите заново.");
    const pricePerHalf = money(option.price);
    cutting = { id: String(option.id), name: String(option.name || "").slice(0, 60), pricePerHalf, amount: pricePerHalf * halves };
  }

  const cities = storefront?.delivery || [];
  const pickup = storefront?.pickup === true;
  let delivery;
  if (deliveryId === "pickup") {
    if (!pickup) throw new HttpsError("failed-precondition", "Хозяйство не предлагает самовывоз.");
    delivery = { mode: "pickup", id: null, city: null, amount: 0 };
  } else if (deliveryId) {
    const city = cities.find((c) => c && c.id === deliveryId);
    if (!city) throw new HttpsError("failed-precondition", "В этот город хозяйство больше не доставляет — выберите заново.");
    delivery = { mode: "city", id: String(city.id), city: String(city.city || "").slice(0, 60), amount: money(city.price) };
  } else {
    // A farm that has not set up its tariffs yet: delivery is agreed with it directly, as before.
    if (cities.length || pickup) throw new HttpsError("invalid-argument", "Выберите доставку.");
    delivery = { mode: "agree", id: null, city: null, amount: 0 };
  }

  return {
    meat, estimatedWeightKg, pricePerKg: pricePerKg || null, cutting, delivery,
    total: meat + (cutting ? cutting.amount : 0) + delivery.amount,
  };
}

/** "2026-10-01" within the next few months, or throws. Kazakhstan is UTC+5 - close enough by date. */
function checkDeliveryDate(raw) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(raw)) throw new HttpsError("invalid-argument", "Некорректная дата доставки.");
  const day = Date.parse(raw + "T00:00:00Z");
  const today = Date.parse(new Date(Date.now() + 5 * 3600 * 1000).toISOString().slice(0, 10) + "T00:00:00Z");
  if (!Number.isFinite(day) || day < today || day > today + MAX_DELIVERY_DAYS_AHEAD * 86400000) {
    throw new HttpsError("invalid-argument", "Выберите дату доставки в ближайшие месяцы.");
  }
}

/**
 * Places an order: a half or a whole carcass with the farm's cutting and delivery ({ format,
 * cuttingId, deliveryId }), or - the older way the mobile apps' flow still describes - a number of
 * shares ({ shares }).
 *
 * Server-side because the client cannot be trusted with any of it: the buyer app's buyShare()
 * never checks that the lot is actually `open`, nothing anywhere flips a sold-out lot to
 * `fully_booked`, and a browser could otherwise write whatever bookedShares - or price - it liked.
 * One Admin-SDK transaction also keeps the share count, the order and the legacy purchase doc
 * from drifting apart.
 *
 * Idempotent: the caller passes a key it generated once per attempt, and a replay - a retried
 * request, a double tap that beat the disabled button, a flaky connection - returns the original
 * order instead of booking the shares again. Without this, a dropped response during payment
 * means the buyer is charged twice for shares they meant to buy once.
 */
export const createOrder = onCall(CALLABLE, async (request) => {
  const auth = request.auth;
  const uid = requireRealUser(auth);
  const data = request.data || {};

  const lotId = String(data.lotId || "").trim();
  const format = data.format == null ? null : String(data.format);
  const legacyShares = Number(data.shares);
  const cuttingId = data.cuttingId ? String(data.cuttingId) : null;
  const deliveryId = data.deliveryId ? String(data.deliveryId) : null;
  const deliveryAddress = String(data.deliveryAddress || "").trim().slice(0, 300);
  const contactPhone = String(data.contactPhone || "").trim().slice(0, 40);
  const deliveryDate = data.deliveryDate ? String(data.deliveryDate) : null;
  const deliverySlot = data.deliverySlot ? String(data.deliverySlot) : null;
  const idempotencyKey = String(data.idempotencyKey || "").trim();

  if (!lotId) throw new HttpsError("invalid-argument", "Не указан лот.");
  if (format !== null && !FORMATS.includes(format)) {
    throw new HttpsError("invalid-argument", "Неизвестный формат заказа.");
  }
  if (format === null) {
    if (!Number.isInteger(legacyShares) || legacyShares < 1 || legacyShares > MAX_SHARES_PER_ORDER) {
      throw new HttpsError("invalid-argument", "Некорректное количество долей.");
    }
    // The older flow always delivers to an address; a format order knows only later, from the
    // delivery chosen, whether it needs one.
    if (deliveryAddress.length < 5) throw new HttpsError("invalid-argument", "Укажите адрес доставки.");
  }
  if (deliverySlot && !DELIVERY_SLOTS.includes(deliverySlot)) {
    throw new HttpsError("invalid-argument", "Некорректное время доставки.");
  }
  if (deliveryDate) checkDeliveryDate(deliveryDate);
  if (contactPhone.length < 6) {
    throw new HttpsError("invalid-argument", "Укажите контактный телефон.");
  }
  if (idempotencyKey.length < 8 || idempotencyKey.length > 128) {
    throw new HttpsError("invalid-argument", "Некорректный ключ идемпотентности.");
  }

  const lotRef = db.collection("lots").doc(lotId);
  const orderRef = db.collection("orders").doc();
  const purchaseRef = db.collection("clients").doc(uid).collection("purchases").doc(lotId);
  // Namespaced by uid so one buyer's key can never collide with - or reveal - another's.
  const intentRef = db.collection("orderIntents").doc(uid + "__" + idempotencyKey);

  let resultOrderId = orderRef.id;
  let replayed = false;
  const pending = [];

  await db.runTransaction(async (tx) => {
    // A transaction can be retried; anything collected by the previous attempt is stale.
    pending.length = 0;
    // Every read first - a staged write makes any later read throw.
    const [intentSnap, lotSnap, purchaseSnap] = await Promise.all([
      tx.get(intentRef), tx.get(lotRef), tx.get(purchaseRef),
    ]);

    if (intentSnap.exists) {
      resultOrderId = intentSnap.data().orderId;
      replayed = true;
      return; // same key, same answer, nothing booked twice
    }

    if (!lotSnap.exists) throw new HttpsError("not-found", "Лот не найден.");
    const lot = lotSnap.data();

    if (lot.status !== "open") {
      throw new HttpsError("failed-precondition", "Лот сейчас не продаётся.");
    }

    // Only a farm the platform has checked sells. Its lots can be prepared while it is on review,
    // and the storefront hides them - this is the same rule where it cannot be bypassed, so money
    // never goes to a farm nobody has checked. Still a read, so still ahead of every write.
    const partnerSnap = await tx.get(db.collection("partners").doc(String(lot.partnerId || "-")));
    if (!partnerSnap.exists || !SELLING_PARTNER_STATUSES.includes(partnerSnap.data().status)) {
      throw new HttpsError("failed-precondition",
        "Хозяйство ещё не прошло проверку платформы — заказ пока недоступен.");
    }

    const total = Number(lot.totalShares) || 0;
    const booked = Number(lot.bookedShares) || 0;
    const shares = format ? sharesFor(lot, format) : legacyShares;
    if (format === "half" && !shares) {
      throw new HttpsError("failed-precondition", "Эта туша продаётся только целиком.");
    }
    if (format === "whole" && booked > 0) {
      throw new HttpsError("failed-precondition", "Целиком эту тушу уже не купить — половина забронирована.");
    }
    if (!shares || booked + shares > total) {
      const free = total - booked;
      throw new HttpsError("failed-precondition", format
        ? "Свободной половины не осталось."
        : `Свободно только ${free} ${pluralRu(free, "доля", "доли", "долей")}.`);
    }

    const pricePerShare = Number(lot.pricePerShare) || 0;
    const pricing = format
      ? priceOrder({ lot, storefront: partnerSnap.data().storefront, format, shares, cuttingId, deliveryId })
      : {
        meat: pricePerShare * shares, estimatedWeightKg: null, pricePerKg: null, cutting: null,
        delivery: { mode: "address", id: null, city: null, amount: 0 }, total: pricePerShare * shares,
      };
    if (pricing.delivery.mode !== "pickup" && deliveryAddress.length < 5) {
      throw new HttpsError("invalid-argument", "Укажите адрес доставки.");
    }
    const amount = pricing.total;
    const now = Timestamp.now();

    writeOrder(tx, {
      orderRef, lotRef, lot, lotId, booked, total, shares, pricing, format, now,
      buyerUid: uid,
      buyerPhone: auth.token?.phone_number || null,
      contactPhone, deliveryAddress, deliveryDate, deliverySlot, idempotencyKey,
      purchaseRef, purchaseSnap,
    });

    tx.set(intentRef, { orderId: orderRef.id, uid, createdAt: now });

    // The farm has to hear about an order without watching its cabinet all day.
    pending.push({
      to: { uid: lot.partnerId, role: "partner" },
      kind: "order_new",
      title: "Новый заказ",
      body: `${lot.name || "Лот"} · ${FORMAT_LABEL[format] || `${shares} ${pluralRu(shares, "доля", "доли", "долей")}`} · ${tenge(amount)}`,
      link: `/cabinet/order?id=${orderRef.id}`,
      orderId: orderRef.id,
    });
    pending.forEach((n) => notify(tx, n));
  });

  await queueEmails(pending);
  return { orderId: resultOrderId, replayed };
});

/**
 * Writes an order and everything that has to move with it: the lot's booked shares, the legacy
 * purchase mirror the buyer app reads, and the order document itself. A plain order and a joint
 * purchase both go through here, so the two can never drift apart.
 *
 * Every read it depends on (the lot, the purchase mirror) is done by the caller - a transaction
 * refuses to read after its first write.
 */
function writeOrder(tx, {
  orderRef, lotRef, lot, lotId, booked, total, shares, pricing, format, now,
  buyerUid, buyerPhone, contactPhone, deliveryAddress, deliveryDate, deliverySlot,
  idempotencyKey = null, purchaseRef, purchaseSnap, group = null,
}) {
  const amount = pricing.total;
  const pricePerShare = Number(lot.pricePerShare) || 0;
  const nowBooked = booked + shares;

  const lotUpdate = { bookedShares: FieldValue.increment(shares) };
  // Nothing in either app ever did this, so lots sat at `open` forever and the statuses
  // after it were unreachable.
  if (nowBooked >= total) lotUpdate.status = "fully_booked";
  tx.update(lotRef, lotUpdate);

  tx.set(orderRef, {
    buyerUid,
    buyerPhone,
    partnerId: lot.partnerId,
    lotId,
    lotTitle: lot.name || "",
    shares,
    pricePerShare,
    amount,
    currency: CURRENCY,

    // What was bought and how the amount was made up. The meat part is an estimate on the
    // lot's approximate weight until the control weighing after slaughter.
    format,
    estimatedWeightKg: pricing.estimatedWeightKg,
    pricePerKg: pricing.pricePerKg,
    pricing: {
      meat: pricing.meat,
      cutting: pricing.cutting ? pricing.cutting.amount : 0,
      delivery: pricing.delivery.amount,
      total: pricing.total,
    },
    cutting: pricing.cutting,
    delivery: pricing.delivery,
    deliveryDate,
    deliverySlot,

    // A joint purchase: who shares this order and what each of them pays. `memberUids` is what
    // the rules read, so every participant can follow the order - while the decisions that are
    // the buyer's (confirming, disputing, cancelling) stay with the one who gathered them.
    group,
    memberUids: group ? group.members.map((m) => m.uid) : [],

    // Fulfilment axis. `created` replaces the old `pending_payment`, which named a PAYMENT
    // state on the FULFILMENT axis and would read as a lie the moment money is real. Readers
    // still accept the old value - see FARMER_FLOW.
    status: "created",
    // Append-only trail. The payment work needs it (who moved what, when), and it is also what
    // gives a buyer a timeline of THEIR order - as opposed to the lot-wide production steps,
    // which every co-buyer of the same animal necessarily shares.
    statusHistory: [{ status: "created", at: now, by: buyerUid }],

    payment: initialPayment(buyerUid, { partnerId: lot.partnerId }),
    commission: { ...COMMISSION_RATES, amount: null },

    deliveryAddress: pricing.delivery.mode === "pickup" ? "" : deliveryAddress,
    contactPhone,
    idempotencyKey,
    createdAt: now,
    updatedAt: now,
    paidAt: null,
  });

  // Keep writing the legacy per-buyer purchase doc so ET_side_client's order tracker keeps
  // working unchanged against orders placed from the website. It stays keyed by lotId and keeps
  // aggregating, because that is exactly what the app renders: it lists the collection and
  // matches on the lotId FIELD (order_tracking_screen.dart), so a per-order key would show the
  // same lot twice in its selector. This doc is a denormalised view for the app - `orders` is
  // the source of truth for money - and `orderIds` is the link back, so the two can be
  // reconciled and the mirror dropped once the app moves onto orders.
  if (purchaseSnap.exists) {
    tx.update(purchaseRef, {
      shares: FieldValue.increment(shares),
      amountPaid: FieldValue.increment(amount),
      orderIds: FieldValue.arrayUnion(orderRef.id),
      updatedAt: now,
    });
  } else {
    tx.set(purchaseRef, {
      lotId,
      shares,
      amountPaid: amount,
      orderIds: [orderRef.id],
      purchaseDate: now,
      updatedAt: now,
      lotTitle: lot.name || "",
      imageUrl: lot.imageUrl || null,
    });
  }
}

// =============================================================================================
// Order lifecycle - leadership's windows 2.1 / 2.2 / 1.5, with the 50 / 25 / 25 payouts
//
//   created ─accept─▶ accepted ─identify─▶ animal_selected ─meat_ready─▶ meat_ready
//   meat_ready ─ship─▶ shipped ─handover─▶ delivered ─complete (buyer) or 3 h later─▶ completed
//   shipped | delivered ─dispute (buyer)─▶ disputed ─reviewDispute (staff)─▶ completed
//   created | accepted | animal_selected ─cancel (either side, until the slaughter)─▶ cancelled
//
//   identify    the farm films or photographs the live animal (leadership's step 1)
//   meat_ready  the farm shows the ready meat, attaches documents and weighs it (step 2). The
//               control weighing fixes the real price of the meat, so the difference to the
//               estimate is settled here - a surcharge or a refund
//   ship        the order leaves the farm (step 3)
//   handover    it reached the buyer (step 4). The buyer then has 3 hours to confirm or dispute;
//               after that the deal completes by itself
//
// Money follows the steps. The farm's share - the total less the 10 % commission - is paid in
// three parts: 50 % when the farm accepts, 25 % when the meat is ready, the rest when the deal
// completes. The advance is fixed at acceptance; the weighing moves the other two. A dispute holds
// the last part until staff decide. For an order created as `not_required` nothing is paid out: the plan
// is recorded so the farm sees what the platform will pay and when, and the pilot settles directly.
//
// Orders placed before this flow carry the old statuses and are read as their new equivalents.
// The old action 'advance' keeps working for pages that still send it.
// =============================================================================================
const AUTO_COMPLETE_MS = 3 * 3600 * 1000;
const LEGACY_STAGE = { pending_payment: "created", confirmed: "accepted", in_progress: "animal_selected" };
const stageOf = (status) => LEGACY_STAGE[status] || status;

const ORDER_ACTIONS = {
  accept: { by: "partner", from: ["created"], to: "accepted" },
  identify: { by: "partner", from: ["accepted"], to: "animal_selected" },
  meat_ready: { by: "partner", from: ["animal_selected"], to: "meat_ready" },
  ship: { by: "partner", from: ["meat_ready"], to: "shipped" },
  handover: { by: "partner", from: ["shipped"], to: "delivered" },
  complete: { by: "buyer", from: ["shipped", "delivered"], to: "completed" },
  autocomplete: { by: "either", from: ["delivered"], to: "completed" },
  dispute: { by: "buyer", from: ["shipped", "delivered"], to: "disputed" },
  cancel: { by: "either", from: ["created", "accepted", "animal_selected"], to: "cancelled" },
};

// Why an action is not possible from where the order is - said in the words of the step.
const TOO_EARLY_OR_LATE = {
  accept: "Заказ уже принят или закрыт.",
  identify: "Сначала примите заказ.",
  meat_ready: "Сначала покажите животное (шаг 1).",
  ship: "Сначала покажите готовое мясо и взвешивание (шаг 2).",
  handover: "Сначала отправьте заказ (шаг 3).",
  complete: "Завершить сделку можно после отправки заказа.",
  autocomplete: "Заказ ещё не передан покупателю.",
  dispute: "Спор открывается при получении заказа.",
  cancel: "После забоя заказ уже нельзя отменить.",
};

// The old flow, for pages that still send 'advance'.
const FARMER_FLOW = { created: "confirmed", pending_payment: "confirmed", confirmed: "in_progress", in_progress: "delivered" };
const AWAITING_FARMER = ["created", "pending_payment"];
const MAX_STEP_FILES = 10;

/** The farm's share and its three parts. The advance, once fixed at acceptance, never moves. */
function payoutAmounts(order, total) {
  const pct = Number(order.commission?.totalPct ?? COMMISSION_RATES.totalPct);
  const net = Math.round((total * (100 - pct)) / 100);
  const advance = order.payouts?.advance?.amount ?? Math.round(net * 0.5);
  const rest = Math.max(0, net - advance);
  const meat = Math.round(rest / 2);
  return { net, advance, meat, final: rest - meat };
}

/**
 * The payout plan with some parts moved to a new state:
 *   locked    - its step has not happened yet
 *   unlocked  - its step happened; with payments on, it is paid out
 *   blocked   - held by an open dispute
 *   withheld  - the dispute went against the farm
 *   cancelled - the order was cancelled
 */
function payoutPlan(order, total, changes, now) {
  const amounts = payoutAmounts(order, total);
  const prev = order.payouts || {};
  const part = (key) => {
    const was = prev[key] || {};
    return {
      amount: amounts[key],
      status: changes[key] || was.status || "locked",
      at: changes[key] ? now : (was.at || null),
    };
  };
  return { net: amounts.net, advance: part("advance"), meat: part("meat"), final: part("final") };
}

const orderTotal = (order) => (order.weighing?.total ?? Number(order.amount)) || 0;

/** What completing a deal writes - by the buyer, by the clock, or by a staff decision. */
function completionUpdate(order, now, by, finalStatus = "unlocked") {
  return {
    status: "completed",
    completedAt: now,
    completedBy: by,
    payouts: payoutPlan(order, orderTotal(order), { final: finalStatus }, now),
  };
}

/**
 * A download URL of a file uploaded to this project's Storage under `prefix` - nothing else goes
 * onto an order. Checked so a farm cannot hang an arbitrary link (or another farm's file) on an
 * order a buyer will open.
 */
function isOwnFile(url, prefix) {
  let u;
  try {
    u = new URL(String(url));
  } catch (_) {
    return false;
  }
  // Against the emulators the Storage host is whatever the client could reach: 127.0.0.1 from a
  // browser on this machine, 10.0.2.2 from an Android emulator, localhost from either. In
  // production only Firebase's own host counts.
  const localHosts = ["127.0.0.1", "localhost", "10.0.2.2"];
  const hostOk = (u.protocol === "https:" && u.hostname === "firebasestorage.googleapis.com")
    || (process.env.FUNCTIONS_EMULATOR === "true" && localHosts.includes(u.hostname));
  return hostOk && u.pathname.includes("/o/" + encodeURIComponent(prefix));
}

function stepFiles(list, prefix, { min, kinds, missing }) {
  const files = Array.isArray(list) ? list : [];
  if (files.length < min) throw new HttpsError("invalid-argument", missing);
  if (files.length > MAX_STEP_FILES) throw new HttpsError("invalid-argument", "Слишком много файлов за один шаг.");
  return files.map((f) => {
    const kind = String(f?.kind || "");
    const url = String(f?.url || "");
    if (!kinds.includes(kind) || !isOwnFile(url, prefix)) {
      throw new HttpsError("invalid-argument", "Файлы шага загружаются со страницы заказа.");
    }
    return { url, kind, name: String(f?.name || "").slice(0, 120) };
  });
}

/**
 * Who hears about a move, and in what words. The buyer follows the farm's steps; the farm hears
 * the decisions that are the buyer's to make. Both are addressed at their own page of the order.
 */
function orderNotes({ action, order, orderId, update, isFarmer }) {
  const lot = order.lotTitle || "Заказ";
  const buyer = (kind, title, body) => ({
    to: { uid: order.buyerUid, role: "buyer" }, kind, title, body, link: `/order?id=${orderId}`, orderId,
  });
  const farm = (kind, title, body) => ({
    to: { uid: order.partnerId, role: "partner" }, kind, title, body, link: `/cabinet/order?id=${orderId}`, orderId,
  });

  switch (action) {
    case "accept":
      return [buyer("order_accepted", "Хозяйство приняло заказ",
        `${lot}. Фермер взял заказ в работу — каждый шаг появится в заказе.`)];
    case "identify":
      return [buyer("order_step", "Фермер показал животное", `${lot}. В заказе появилась съёмка животного.`)];
    case "meat_ready": {
      const w = update.weighing;
      const diff = w ? w.difference : 0;
      // Онлайн-оплата и расчёт напрямую с хозяйством — это разные обещания. Разницу по
      // оплаченному картой заказу мы действительно возвращаем на карту; доплату по нему взять
      // с того же платежа нельзя, поэтому её называют тем, чем она есть, — расчётом на месте.
      const paidOnline = ["captured_partial", "captured_full"].includes(order.payment?.status);
      const money = !w || !w.meat ? ""
        : diff > 0 ? (paidOnline
          ? ` Доплата ${tenge(diff)} — рассчитайтесь с хозяйством при получении.`
          : ` Доплата ${tenge(diff)}.`)
          : diff < 0 ? (paidOnline
            ? ` Возврат ${tenge(-diff)} придёт на ту же карту.`
            : ` Возврат ${tenge(-diff)}.`) : " Сумма заказа не изменилась.";
      const weight = w ? ` Контрольный вес — ${String(w.weightKg).replace(".", ",")} кг.` : "";
      return [buyer("order_step", "Мясо готово", `${lot}.${weight}${money}`)];
    }
    case "ship":
      return [buyer("order_step", "Заказ отправлен", `${lot}. Хозяйство отправило заказ.`)];
    case "handover":
      return [buyer("order_handover", "Заказ передан",
        `${lot}. Подтвердите получение до ${atTime(update.autoCompleteAt)} — после этого сделка завершится сама.`)];
    case "complete":
      return [farm("order_completed", "Покупатель подтвердил получение", `${lot}. Сделка завершена.`)];
    case "autocomplete":
      return [
        farm("order_completed", "Сделка завершена автоматически", `${lot}. Покупатель не подтвердил получение за 3 часа.`),
        buyer("order_completed", "Сделка завершена", `${lot}. Прошло 3 часа после передачи заказа.`),
      ];
    case "dispute":
      return [farm("order_disputed", "Покупатель открыл спор",
        `${lot}. Последняя выплата удержана, пока платформа не примет решение.`)];
    case "cancel":
      return isFarmer
        ? [buyer("order_cancelled", "Хозяйство отменило заказ", `${lot}. Туша снова свободна для заказа.`)]
        : [farm("order_cancelled", "Покупатель отменил заказ", `${lot}. Доли вернулись в лот.`)];
    default:
      return [];
  }
}

/**
 * Moves an order along its lifecycle (see above). Server-side because every move either touches
 * money (the payout plan), stock (cancelling returns the shares to the lot) or evidence (step
 * files, the weighing, a dispute) - and only the two parties to an order may make them, each
 * only their own.
 */
// REKASSA_KEY нужен здесь, а не в ночном сбросе: чек выбивается только там, где деньги реально
// списались или вернулись, а сброс лишь снимает неклиренные холды — фискализировать нечего.
export const updateOrderStatus = onCall({ ...CALLABLE, secrets: [PAY_SECRET, REKASSA_KEY] }, async (request) => {
  const uid = requireRealUser(request.auth);
  const data = request.data || {};
  const orderId = String(data.orderId || "").trim();
  const action = String(data.action || "").trim();
  if (!orderId) throw new HttpsError("invalid-argument", "Не указан заказ.");
  if (action !== "advance" && !ORDER_ACTIONS[action]) {
    throw new HttpsError("invalid-argument", "Неизвестное действие.");
  }

  const orderRef = db.collection("orders").doc(orderId);
  let result = null;
  // Assigned inside the transaction, never appended to: a retry must not send the same letter twice.
  let pending = [];
  // Что списать с холда после коммита транзакции, если фермер принял заказ.
  let capture = null;

  await db.runTransaction(async (tx) => {
    const orderSnap = await tx.get(orderRef);
    if (!orderSnap.exists) throw new HttpsError("not-found", "Заказ не найден.");
    const order = orderSnap.data();

    const isFarmer = order.partnerId === uid;
    const isBuyer = order.buyerUid === uid;
    if (!isFarmer && !isBuyer) throw new HttpsError("permission-denied", "Это не ваш заказ.");

    const now = Timestamp.now();
    const history = Array.isArray(order.statusHistory) ? order.statusHistory : [];
    const trail = (status) => [...history, { status, at: now, by: uid }];

    // ---- the old flow ------------------------------------------------------------------------
    if (action === "advance") {
      if (!isFarmer) throw new HttpsError("permission-denied", "Статус меняет фермер.");
      const next = FARMER_FLOW[order.status];
      if (!next) throw new HttpsError("failed-precondition", "Из этого статуса дальше двигать некуда.");
      // Work does not start on unpaid money - a no-op for orders created as `not_required`.
      if (AWAITING_FARMER.includes(order.status) && !paymentClearsFulfilment(order.payment)) {
        throw new HttpsError("failed-precondition", "Заказ ещё не оплачен.");
      }
      tx.update(orderRef, { status: next, statusHistory: trail(next), updatedAt: now });
      result = { status: next };
      return;
    }

    // ---- the lifecycle -----------------------------------------------------------------------
    const rule = ORDER_ACTIONS[action];
    if (rule.by === "partner" && !isFarmer) throw new HttpsError("permission-denied", "Этот шаг выполняет хозяйство.");
    if (rule.by === "buyer" && !isBuyer) throw new HttpsError("permission-denied", "Это решает покупатель.");
    const stage = stageOf(order.status);
    if (!rule.from.includes(stage)) throw new HttpsError("failed-precondition", TOO_EARLY_OR_LATE[action]);
    if (action === "accept" && !paymentClearsFulfilment(order.payment)) {
      throw new HttpsError("failed-precondition", "Заказ ещё не оплачен.");
    }

    const update = { status: rule.to, statusHistory: trail(rule.to), updatedAt: now };
    const ownFiles = `orders/${order.partnerId}/${orderId}/`;
    const partnerRef = db.collection("partners").doc(String(order.partnerId || "-"));

    switch (action) {
      case "accept":
        update.acceptedAt = now;
        update.payouts = payoutPlan(order, orderTotal(order), { advance: "unlocked" }, now);
        break;

      case "identify":
        update["steps.identify"] = {
          at: now,
          files: stepFiles(data.files, ownFiles, {
            min: 1, kinds: ["photo", "video"], missing: "Снимите животное — нужно хотя бы одно фото или видео.",
          }),
        };
        break;

      case "meat_ready": {
        const files = stepFiles(data.files, ownFiles, {
          min: 1, kinds: ["photo", "video"], missing: "Покажите готовое мясо — нужно хотя бы одно фото или видео.",
        });
        const documents = stepFiles(data.documents, ownFiles, { min: 0, kinds: ["photo", "doc"], missing: "" });
        const scalePhoto = data.scalePhoto
          ? stepFiles([data.scalePhoto], ownFiles, { min: 1, kinds: ["photo"], missing: "" })[0] : null;

        // The control weighing. With a price per kilogram it fixes the real price of the meat;
        // an older order without one records the weight only.
        const perKg = Number(order.pricePerKg) || 0;
        const weightKg = Math.round(Number(data.weightKg) * 10) / 10;
        const weighed = weightKg > 0 && weightKg <= 2000;
        if (perKg > 0 && !weighed) throw new HttpsError("invalid-argument", "Укажите вес по контрольному взвешиванию.");
        let weighing = null;
        if (weighed) {
          const meat = perKg > 0 ? Math.round(perKg * weightKg) : null;
          const total = perKg > 0
            ? meat + (Number(order.pricing?.cutting) || 0) + (Number(order.pricing?.delivery) || 0)
            : (Number(order.amount) || 0);
          weighing = { weightKg, meat, total, difference: total - (Number(order.amount) || 0), scalePhoto, at: now };
        }

        // The animal's own certificates travel with the order to the buyer. Reads, so before any
        // write - and nothing above has written yet.
        const lotSnap = await tx.get(db.collection("lots").doc(String(order.lotId || "-")));
        const animalIds = lotSnap.exists ? (lotSnap.data().animalIds || []).slice(0, 5) : [];
        const certSnaps = await Promise.all(animalIds.map((id) => tx.get(db.collection("animals").doc(id).collection("documents"))));
        const certificates = certSnaps.flatMap((s) => s.docs.map((d) => d.data()))
          .filter((d) => d.status !== "rejected" && d.fileUrl)
          .map((d) => ({ label: String(d.label || "Документ").slice(0, 120), url: String(d.fileUrl), status: d.status || "pending" }));

        update["steps.meat"] = { at: now, files, documents, certificates };
        if (weighing) update.weighing = weighing;
        update.payouts = payoutPlan(order, weighing ? weighing.total : orderTotal(order), { meat: "unlocked" }, now);
        break;
      }

      case "ship":
        update["steps.shipped"] = { at: now };
        break;

      case "handover":
        update["steps.handover"] = { at: now };
        update.autoCompleteAt = Timestamp.fromMillis(now.toMillis() + AUTO_COMPLETE_MS);
        break;

      case "complete":
      case "autocomplete":
        if (action === "autocomplete" && !(order.autoCompleteAt && order.autoCompleteAt.toMillis() <= now.toMillis())) {
          throw new HttpsError("failed-precondition", "Время на подтверждение у покупателя ещё не вышло.");
        }
        Object.assign(update, completionUpdate(order, now, action === "complete" ? "buyer" : "auto"));
        tx.update(partnerRef, { totalDeals: FieldValue.increment(1) });
        break;

      case "dispute": {
        const description = String(data.description || "").trim().slice(0, 2000);
        if (description.length < 5) throw new HttpsError("invalid-argument", "Опишите, что не так.");
        const mediaUrl = data.mediaUrl ? String(data.mediaUrl) : null;
        if (mediaUrl && !isOwnFile(mediaUrl, `disputes/${uid}/`)) {
          throw new HttpsError("invalid-argument", "Фото или видео загружается со страницы заказа.");
        }
        const disputeRef = db.collection("disputes").doc();
        tx.set(disputeRef, {
          uid, orderId, lotId: order.lotId || null, partnerId: order.partnerId || null,
          description, mediaUrl, status: "new", createdAt: now,
        });
        update.disputeId = disputeRef.id;
        update.payouts = payoutPlan(order, orderTotal(order), { final: "blocked" }, now);
        break;
      }

      case "cancel": {
        // Отмена заказа, по которому прошли деньги, — это возврат, и он разный в зависимости от
        // того, успели ли списать. Неклиренный холд снимается `cancel` (revoke по нему не
        // работает — так сказано в документации), списанный платёж возвращается `revoke`.
        // Статус ставим сразу, чтобы человек увидел правду в ту же секунду; сам запрос уходит
        // после коммита транзакции.
        const paid = order.payment?.status;
        if (paid === "authorized") {
          update["payment.status"] = "cancelled";
        } else if (paid === "captured_partial" || paid === "captured_full") {
          update["payment.status"] = "refund_pending";
        }
        // All reads before any write.
        const lotRef = db.collection("lots").doc(order.lotId);
        const purchaseRef = db.collection("clients").doc(order.buyerUid).collection("purchases").doc(order.lotId);
        const [lotSnap, purchaseSnap] = await Promise.all([tx.get(lotRef), tx.get(purchaseRef)]);
        const orderShares = Number(order.shares) || 0;
        const orderAmount = Number(order.amount) || 0;

        // Give the shares back, and re-open the lot if this order was what sold it out.
        if (lotSnap.exists) {
          const lot = lotSnap.data();
          const booked = Number(lot.bookedShares) || 0;
          const returned = Math.min(orderShares, booked);
          const lotUpdate = { bookedShares: booked - returned };
          if (lot.status === "fully_booked" && returned > 0) lotUpdate.status = "open";
          tx.update(lotRef, lotUpdate);
        }
        // The legacy purchase doc the buyer app renders must not keep showing a cancelled order.
        if (purchaseSnap.exists) {
          const purchase = purchaseSnap.data();
          const remainingShares = (Number(purchase.shares) || 0) - orderShares;
          if (remainingShares > 0) {
            tx.update(purchaseRef, {
              shares: remainingShares,
              amountPaid: Math.max(0, (Number(purchase.amountPaid) || 0) - orderAmount),
              orderIds: FieldValue.arrayRemove(orderId),
              updatedAt: now,
            });
          } else {
            tx.delete(purchaseRef);
          }
        }
        update.cancelledBy = isFarmer ? "partner" : "buyer";
        if (order.payouts) {
          update.payouts = payoutPlan(order, orderTotal(order), { advance: "cancelled", meat: "cancelled", final: "cancelled" }, now);
        }
        break;
      }
    }

    tx.update(orderRef, update);
    pending = orderNotes({ action, order, orderId, update, isFarmer });
    pending.forEach((n) => notify(tx, n));
    result = { status: rule.to };
    // Обращение к их API нельзя делать внутри транзакции - это сетевой вызов наружу, а транзакция
    // Firestore может быть повторена, и тогда деньги ушли бы дважды. Запоминаем намерение и
    // выполняем после коммита.
    const paymentId = String(order.payment?.providerPaymentId || "");
    const money = orderTotal(order);
    if (action === "accept" && order.payment?.status === "authorized") {
      capture = { kind: "capture", paymentId, amount: money };
    } else if (action === "cancel" && order.payment?.status === "authorized") {
      capture = { kind: "release", paymentId, amount: money };
    } else if (action === "cancel"
        && ["captured_partial", "captured_full"].includes(order.payment?.status)) {
      capture = { kind: "refund", paymentId, amount: order.payment?.capturedAmount || money };
    } else if (action === "meat_ready" && update.weighing?.difference < 0
        && ["captured_partial", "captured_full"].includes(order.payment?.status)) {
      // Контрольное взвешивание показало недовес. Деньги уже списаны по заявленному весу, и
      // разницу надо вернуть — иначе уведомление «Возврат 8 400 ₸» остаётся обещанием, за
      // которым ничего не следует. Больше, чем списали, вернуть нельзя.
      const back = Math.min(-update.weighing.difference, Number(order.payment?.capturedAmount) || 0);
      if (back > 0) capture = { kind: "adjust", paymentId, amount: back };
    }
  });

  if (capture) await settleMoney(orderRef, orderId, capture);
  await queueEmails(pending);
  return result;
});

/**
 * Completes the deals whose buyers neither confirmed nor disputed within 3 hours of handover. The
 * pages also complete an overdue order themselves when someone opens it (action 'autocomplete'),
 * so a stalled schedule delays nothing a person is looking at.
 */
export const autoCompleteOrders = onSchedule({ schedule: "every 15 minutes", timeZone: "Asia/Almaty" }, async () => {
  const delivered = await db.collection("orders").where("status", "==", "delivered").get();
  let done = 0;
  for (const d of delivered.docs) {
    if (!(d.data().autoCompleteAt?.toMillis() <= Date.now())) continue;
    try {
      await db.runTransaction(async (tx) => {
        const snap = await tx.get(d.ref);
        const order = snap.data();
        if (!snap.exists || order.status !== "delivered" || !(order.autoCompleteAt?.toMillis() <= Date.now())) return;
        const now = Timestamp.now();
        tx.update(db.collection("partners").doc(String(order.partnerId || "-")), { totalDeals: FieldValue.increment(1) });
        tx.update(d.ref, {
          ...completionUpdate(order, now, "auto"),
          statusHistory: [...(order.statusHistory || []), { status: "completed", at: now, by: "system" }],
          updatedAt: now,
        });
        orderNotes({ action: "autocomplete", order, orderId: d.id, update: {}, isFarmer: false })
          .forEach((n) => notify(tx, n));
      });
      done += 1;
    } catch (e) {
      console.error("auto-complete failed for order " + d.id, e);
    }
  }
  if (done) console.log(`auto-completed ${done} order(s)`);
});

/**
 * Закрывает кассовые смены хозяйств на ночь.
 *
 * Смена открывается сама первым чеком и живёт сутки — потом касса отвечает `Shift period
 * expired` и чеки перестают выбиваться. Фермер об этом не узнает до первой непробитой продажи,
 * поэтому закрываем за него.
 *
 * Поздним вечером, а не в полночь: смена, открытая вечерним заказом, успевает закрыться в тот
 * же день, и отчёт ложится на правильную дату.
 *
 * Перебираем хозяйства, а не ищем кассы запросом: записей `private/kassa` коллекционной группой
 * не выбрать (её нельзя отфильтровать по имени документа), а хозяйств десятки, и это раз в
 * сутки. Станет сотни — понадобится отметка на публичном профиле.
 */
export const closeKassaShifts = onSchedule(
  { schedule: "40 23 * * *", timeZone: "Asia/Almaty", secrets: [REKASSA_KEY] },
  async () => {
    const base = process.env.REKASSA_BASE;
    if (!base) return;
    const apiKey = REKASSA_KEY.value();
    if (!apiKey) return;

    const rk = await import("./rekassa.js");
    const partners = await db.collection("partners").get();
    let closed = 0;
    let failed = 0;

    for (const p of partners.docs) {
      const accessSnap = await p.ref.collection("private").doc("kassa").get();
      if (!accessSnap.exists) continue;
      const access = accessSnap.data();
      try {
        const session = await rk.connect(base, apiKey, { znm: access.znm, password: access.password });
        if (!session.shiftOpen) continue;
        await rk.closeShift(base, session, access.pin, `${p.id}-shift-${session.shiftNumber}`);
        closed++;
      } catch (e) {
        // Одна упавшая касса не должна остановить остальные: у каждого хозяйства своя.
        failed++;
        console.error("rekassa close shift failed", p.id, e?.message || e);
      }
    }
    if (closed || failed) console.log(`kassa shifts: closed ${closed}, failed ${failed}`);
  },
);

// =============================================================================================
// Оплата — Freedom Pay
//
// Три функции: покупатель просит ссылку на оплату (startPayment), их сервер спрашивает нас перед
// списанием (freedompayCheck) и сообщает результат (freedompayResult).
//
// Что здесь важно понимать, прежде чем менять:
//
// 1. Сумму берём ИЗ ЗАКАЗА, а не из запроса. Клиент не участвует в назначении цены нигде — и в
//    платеже это перестаёт быть вопросом вкуса.
// 2. Два обработчика открыты в интернет, потому что их вызывает Freedom Pay. Открыты — значит
//    их может вызвать кто угодно, и единственное, что отделяет уведомление об оплате от чужого
//    POST'а, это подпись. Поэтому подпись проверяется ДО первого чтения из базы. Здесь уже был
//    урок: триггер pushNotification однажды принимал неаутентифицированные POST'ы, потому что
//    invoker: public висел не на том ресурсе. На платёжном вебхуке та же ошибка стоит дороже.
// 3. Уведомление приходит повторно каждые полчаса два часа подряд, пока мы не ответим 200 с их
//    XML, и документация прямо требует переваривать дубликаты. Поэтому payments/{pg_payment_id}
//    — журнал: второй раз тот же платёж ничего не меняет и получает тот же ответ.
// 4. Платёж двухстадийный (pg_auto_clearing=0): сначала холд, списание — когда хозяйство примет
//    заказ. И ловушка: если за 5 дней не прислать ни клиринг, ни отмену, Freedom спишет сам.
//    Молчание здесь не безопасно — отмену по таймеру делает фаза 4.
// =============================================================================================

// Адрес вынесен в окружение ради одного: тесты поднимают заглушку их API и проверяют, что мы
// шлём правильно подписанный запрос с суммой ИЗ ЗАКАЗА. Без этого шва проверять было бы нечего —
// не ходить же в их боевой сервис на каждом прогоне.
const FP_BASE = process.env.FREEDOMPAY_BASE || "https://api.freedompay.kz";
const FP_INIT_URL = `${FP_BASE}/init_payment.php`;
const FP_INIT_SCRIPT = "init_payment.php";

// Счёт живёт сутки: меньше — и человек, ушедший подумать, вернётся к мёртвой ссылке.
const PAY_LIFETIME_SEC = 24 * 3600;
// Своё окно переиспользования ссылки — короче, чем счёт: цена заказа может измениться.
const PAY_REUSE_MS = 30 * 60 * 1000;

/** Настройки, которые различаются между эмулятором и продакшеном. */
function fpConfig() {
  const project = process.env.GCLOUD_PROJECT || process.env.GCP_PROJECT || "";
  return {
    merchantId: process.env.FREEDOMPAY_MERCHANT_ID || "000000",
    // Имя нашего обработчика — последний сегмент result_url. Обе стороны считают подпись по
    // адресу, на который сообщение пришло, поэтому это часть протокола, а не название на вкус.
    resultScript: process.env.FREEDOMPAY_RESULT_SCRIPT || "freedompayResult",
    checkScript: process.env.FREEDOMPAY_CHECK_SCRIPT || "freedompayCheck",
    callbackBase: process.env.FREEDOMPAY_CALLBACK_BASE
      || `https://europe-west3-${project}.cloudfunctions.net`,
    site: process.env.ET_SITE_URL || "https://example.kz",
    // Тестовый режим — всё, что не помечено явно боевым. Ошибиться в эту сторону безопасно.
    testing: process.env.FREEDOMPAY_LIVE === "true" ? 0 : 1,
  };
}

/**
 * Запрос к их API: подписываем, шлём формой, разбираем XML.
 *
 * Отдельная функция, потому что дальше по ней пойдут и клиринг, и отмена, и возврат — а каждое
 * место, где подпись собирают заново, это место, где её однажды соберут не так.
 */
async function fpRequest(script, params) {
  const url = `${FP_BASE}/${script}`;
  const body = new URLSearchParams();
  for (const [key, value] of Object.entries(signed(script, params, PAY_SECRET.value()))) {
    body.append(key, String(value));
  }
  const response = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
    signal: AbortSignal.timeout(15000),
  });
  return parseXml(await response.text());
}

/**
 * Движение денег по решению сторон: списать холд, снять его или вернуть списанное.
 *
 * Вызывается ПОСЛЕ коммита транзакции: это сетевой запрос наружу, а транзакция Firestore может
 * быть повторена, и тогда деньги ушли бы дважды.
 *
 * Неудача здесь НЕ откатывает решение. Хозяйство, принявшее заказ, уже начало работу; покупатель,
 * отменивший заказ, уже увидел отмену. Откатывать это из-за сетевой ошибки неправильно — и не
 * нужно, потому что ни один из трёх случаев не теряет денег:
 *
 *   • не списали холд — Freedom спишет его сам на пятые сутки;
 *   • не сняли холд — он истечёт сам, деньги вернутся;
 *   • не отправили возврат — заказ остаётся в `refund_pending`, и это видно и нам, и покупателю.
 *
 * На заказе в любом случае остаётся `payment.error`, чтобы молчаливого расхождения не было.
 */
async function settleMoney(orderRef, orderId, { kind, paymentId, amount }) {
  if (!paymentId) return;
  const merchant = fpConfig().merchantId;
  const plan = {
    // Неклиренный холд снимается именно `cancel`: `revoke` по нему не работает.
    capture: {
      script: "do_capture.php",
      params: { pg_clearing_amount: amount },
      done: { "payment.status": "captured_full", "payment.capturedAmount": amount, "payment.capturedAt": true },
    },
    release: {
      script: "cancel.php",
      params: {},
      done: { "payment.status": "cancelled" },
    },
    refund: {
      script: "revoke.php",
      params: { pg_refund_amount: amount },
      done: { "payment.status": "refunded", "payment.refundedAmount": amount, "payment.refundedAt": true },
    },
    // Возврат разницы после контрольного взвешивания. Тот же revoke, но заказ остаётся
    // оплаченным: вернули часть, а не всё, и статус «возвращено» был бы здесь неправдой.
    adjust: {
      script: "revoke.php",
      params: { pg_refund_amount: amount },
      done: {
        "payment.status": "captured_partial",
        "payment.refundedAmount": amount,
        "payment.refundedAt": true,
      },
    },
  }[kind];
  if (!plan) return;

  try {
    const answer = await fpRequest(plan.script, {
      pg_merchant_id: merchant,
      pg_payment_id: paymentId,
      ...plan.params,
    });
    const ok = answer.pg_status === "ok" || answer.pg_status === "success";
    if (!ok) throw new Error(`${answer.pg_error_code}: ${answer.pg_error_description}`);

    const now = Timestamp.now();
    const update = { "payment.error": null, updatedAt: now };
    for (const [key, value] of Object.entries(plan.done)) update[key] = value === true ? now : value;
    await orderRef.update(update);

    // Деньги двинулись — значит пора за чеком. Отдельно и после, потому что это второй внешний
    // сервис: падение re:Kassa не должно откатывать уже списанные деньги.
    await fiscalise(orderRef, orderId, { kind, amount });
  } catch (e) {
    console.error(`freedompay ${plan.script} failed`, orderId, paymentId, e);
    await orderRef.update({ "payment.error": `${kind}: ${String(e?.message || e)}`.slice(0, 300) })
      .catch(() => {});
  }
}

/**
 * Фискальный чек по заказу — от имени ХОЗЯЙСТВА, а не платформы.
 *
 * Вызывается после того, как деньги реально двинулись: списали — чек продажи, вернули часть или
 * всё — чек возврата со ссылкой на продажу. Холд, снятый до списания, чека не порождает: денег
 * не брали, и фискализировать нечего.
 *
 * Ошибка здесь НЕ откатывает заказ. Невыбитый чек — это нарушение, и его надо чинить, но
 * откатывать принятый заказ и списанные деньги из-за недоступности кассы хуже: покупатель уже
 * заплатил, хозяйство уже начало работу. Поэтому промах остаётся на заказе в `fiscal.error`,
 * видимый и нам, и в админке, а не растворяется в логах.
 *
 * Пока в окружении нет адреса re:Kassa — фискализация выключена целиком и молча. Так код можно
 * выкатить раньше, чем подпишут договор, и ничего не сломать.
 */
async function fiscalise(orderRef, orderId, { kind, amount }) {
  if (!["capture", "adjust", "refund"].includes(kind)) return;
  const base = process.env.REKASSA_BASE;
  if (!base) return;

  try {
    const apiKey = REKASSA_KEY.value();
    if (!apiKey) return;

    const snap = await orderRef.get();
    if (!snap.exists) return;
    const order = snap.data();

    const accessSnap = await db.collection("partners").doc(String(order.partnerId || ""))
      .collection("private").doc("kassa").get();
    if (!accessSnap.exists) {
      await orderRef.update({ "fiscal.error": "Касса хозяйства не подключена — чек не выбит." });
      return;
    }
    const access = accessSnap.data();
    const rk = await import("./rekassa.js");
    const session = await rk.connect(base, apiKey, { znm: access.znm, password: access.password });

    const now = new Date();
    let issued;
    if (kind === "capture") {
      issued = await rk.issue(base, session, rk.sellTicket({
        title: `${order.lotTitle || "Мясо"} — ${order.format === "whole" ? "целая туша" : "половина туши"}`,
        weightKg: Number(order.weighing?.weightKg) || Number(order.estimatedWeightKg) || 0,
        pricePerKg: Number(order.pricePerKg) || 0,
        meat: Number(order.pricing?.meat) || Number(order.amount) || 0,
        cutting: Number(order.pricing?.cutting) || 0,
        delivery: Number(order.pricing?.delivery) || 0,
      }, now), `${orderId}-sell`);
      await orderRef.update({
        fiscal: {
          ticketNumber: issued.ticketNumber, url: issued.url, kgdKkmId: issued.kgdKkmId,
          total: Number(order.amount) || 0, at: Timestamp.fromDate(now), error: null,
          // Пока контур тестовый, чек об этом говорит сам. Иначе покупателю покажут пробный
          // документ как настоящий — и приложение, и сайт читают именно этот признак.
          test: rk.isTestBase(base),
        },
      });
      return;
    }

    // Возврат без продажи привязать не к чему: такой чек налоговая увидит как отдельную
    // операцию непонятно за что. Лучше честно сказать, чем выбить оторванный документ.
    const parent = order.fiscal;
    if (!parent?.ticketNumber) {
      await orderRef.update({ "fiscal.error": "Чек продажи не выбивался — возврат привязать не к чему." });
      return;
    }
    issued = await rk.issue(base, session, rk.returnTicket({
      amount,
      weightKg: Number(order.pricePerKg) > 0 ? amount / Number(order.pricePerKg) : 0,
      pricePerKg: Number(order.pricePerKg) || 0,
      parent: {
        kgdKkmId: parent.kgdKkmId || session.kgdKkmId,
        ticketNumber: parent.ticketNumber,
        total: parent.total,
        at: parent.at?.toDate ? parent.at.toDate() : new Date(parent.at || now),
      },
    }, now), `${orderId}-return-${amount}`);
    await orderRef.update({
      fiscalReturn: {
        ticketNumber: issued.ticketNumber, url: issued.url,
        amount, at: Timestamp.fromDate(now), test: rk.isTestBase(base),
      },
      "fiscal.error": null,
    });
  } catch (e) {
    console.error("rekassa failed", orderId, kind, e);
    await orderRef.update({ "fiscal.error": `${kind}: ${String(e?.message || e)}`.slice(0, 300) })
      .catch(() => {});
  }
}

/** Что покупатель увидит на странице оплаты и в чеке. */
function paymentDescription(order) {
  const what = order.lotTitle || "Заказ";
  const format = order.format === "whole" ? "целая туша" : "половина туши";
  return `${what} — ${format}`.slice(0, 255);
}

/**
 * Покупатель просит ссылку на оплату.
 *
 * Возвращает pg_redirect_url — страницу Freedom Pay. Карту вводят там: у себя мы её не видим,
 * не получаем и не храним, и PCI DSS нам поэтому не нужен.
 */
export const startPayment = onCall({ ...CALLABLE, secrets: [PAY_SECRET] }, async (request) => {
  const uid = requireRealUser(request.auth);
  const orderId = String(request.data?.orderId || "").trim();
  if (!orderId) throw new HttpsError("invalid-argument", "Не указан заказ.");

  const orderRef = db.collection("orders").doc(orderId);
  const snap = await orderRef.get();
  if (!snap.exists) throw new HttpsError("not-found", "Заказ не найден.");
  const order = snap.data();

  if (order.buyerUid !== uid) {
    // Участник складчины заказ видит и следит за ним наравне со всеми — но платит организатор,
    // одной суммой за всех. Сказать такому человеку «это не ваш заказ» было бы неправдой.
    const inGroup = Array.isArray(order.memberUids) && order.memberUids.includes(uid);
    throw new HttpsError("permission-denied", inGroup
      ? "Совместную покупку оплачивает организатор — доли он соберёт с участников сам."
      : "Это не ваш заказ.");
  }
  if (stageOf(order.status) !== "created") {
    throw new HttpsError("failed-precondition", "Этот заказ уже не ждёт оплаты.");
  }

  const payment = order.payment || {};
  if (PAYMENT_SETTLED.includes(payment.status)) {
    throw new HttpsError("failed-precondition", "Заказ уже оплачен.");
  }
  // Заказ пилота: по нему расчёт идёт напрямую с хозяйством, и это записано на нём самом ещё
  // при создании. Сайт зовёт startPayment на всякий заказ и по этому отказу понимает, что
  // показывать прежний экран, — поэтому формулировка здесь не техническая.
  if (payment.status === "not_required") {
    throw new HttpsError("failed-precondition",
      "По этому заказу расчёт идёт напрямую с хозяйством.");
  }
  if (!["awaiting", "failed", "expired"].includes(payment.status)) {
    throw new HttpsError("failed-precondition", "Этот заказ сейчас нельзя оплатить.");
  }

  // Ссылка, выданная минуту назад, — это та же попытка, а не новая. Иначе двойное нажатие
  // заводит у Freedom два платежа на один заказ, и один из них потом придётся отменять.
  const issuedAt = payment.redirectAt?.toMillis?.() ?? 0;
  if (payment.redirectUrl && Date.now() - issuedAt < PAY_REUSE_MS) {
    return { redirectUrl: payment.redirectUrl, paymentId: payment.providerPaymentId || null };
  }

  const config = fpConfig();
  const total = orderTotal(order);
  if (!Number.isInteger(total) || total <= 0) {
    throw new HttpsError("failed-precondition", "У заказа нет суммы к оплате.");
  }

  const attempt = Number(payment.attempts || 0) + 1;
  const params = signed(FP_INIT_SCRIPT, {
    pg_merchant_id: config.merchantId,
    pg_order_id: orderId,
    pg_amount: total,
    pg_currency: order.currency || CURRENCY,
    pg_description: paymentDescription(order),
    pg_lifetime: PAY_LIFETIME_SEC,
    // Холд, а не списание: деньги уходят, когда хозяйство приняло заказ.
    pg_auto_clearing: "0",
    pg_check_url: `${config.callbackBase}/${config.checkScript}`,
    pg_result_url: `${config.callbackBase}/${config.resultScript}`,
    pg_success_url: `${config.site}/order?id=${encodeURIComponent(orderId)}&paid=1`,
    pg_failure_url: `${config.site}/order?id=${encodeURIComponent(orderId)}&paid=0`,
    pg_request_method: "POST",
    // Ключ новый на каждую попытку: иначе повтор после отказа вернёт тот же отказавший платёж.
    pg_idempotency_key: `${orderId}-${attempt}`,
    pg_user_id: uid,
    pg_user_phone: String(order.contactPhone || "").replace(/\D/g, ""),
    pg_testing_mode: config.testing,
    pg_language: "ru",
    pg_param1: uid,
  }, PAY_SECRET.value());

  let answer;
  try {
    const body = new URLSearchParams();
    for (const [key, value] of Object.entries(params)) body.append(key, String(value));
    const response = await fetch(FP_INIT_URL, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body,
      signal: AbortSignal.timeout(15000),
    });
    answer = parseXml(await response.text());
  } catch (e) {
    console.error("freedompay init_payment failed", orderId, e);
    throw new HttpsError("unavailable", "Платёжный сервис не отвечает. Попробуйте ещё раз.");
  }

  const ok = answer.pg_status === "ok" || answer.pg_status === "success";
  if (!ok || !answer.pg_redirect_url) {
    // 9998 означает, что разошёлся наш алгоритм подписи, и это наша авария, а не их отказ:
    // покупателю про подпись знать нечего, а в логе это надо видеть отдельной строкой.
    console.error("freedompay refused init_payment", orderId,
      answer.pg_error_code, answer.pg_error_description);
    throw new HttpsError("unavailable",
      answer.pg_error_description || "Не удалось начать оплату. Попробуйте ещё раз.");
  }

  const now = Timestamp.now();
  await orderRef.update({
    "payment.provider": "freedompay",
    "payment.providerPaymentId": String(answer.pg_payment_id || ""),
    "payment.redirectUrl": answer.pg_redirect_url,
    "payment.redirectAt": now,
    "payment.attempts": attempt,
    updatedAt: now,
  });

  return { redirectUrl: answer.pg_redirect_url, paymentId: String(answer.pg_payment_id || "") };
});

/** Параметры их callback'а: query или тело, в зависимости от того, как они его прислали. */
function callbackParams(req) {
  const body = parseCallbackBody(req.get("content-type"), req.rawBody);
  return { ...(req.query || {}), ...body };
}

/**
 * Ответ им и ничего больше. Наше XML подписано тем же ключом — иначе они не считают ответ
 * полученным и будут слать уведомление ещё два часа.
 */
function sendXml(res, script, status, description) {
  res.set("Content-Type", "application/xml; charset=utf-8");
  res.status(200).send(replyXml(script, status, description, PAY_SECRET.value()));
}

/**
 * Их вопрос перед списанием: можно ли принимать платёж по этому заказу.
 *
 * Отвечаем `rejected`, если долю успели купить или заказ уже ушёл дальше. Это единственная
 * точка, где ещё можно не дать деньгам уйти, — после списания останется только возврат.
 */
export const freedompayCheck = onRequest(
  { invoker: "public", secrets: [PAY_SECRET] },
  async (req, res) => {
    const config = fpConfig();
    const params = callbackParams(req);

    if (!verify(config.checkScript, params, PAY_SECRET.value())) {
      console.warn("freedompayCheck: bad signature", params.pg_order_id || "");
      res.status(403).send("bad signature");
      return;
    }

    try {
      const orderId = String(params.pg_order_id || "");
      const snap = await db.collection("orders").doc(orderId).get();
      if (!snap.exists) {
        sendXml(res, config.checkScript, "rejected", "Заказ не найден.");
        return;
      }
      const order = snap.data();
      if (stageOf(order.status) !== "created") {
        sendXml(res, config.checkScript, "rejected", "Заказ уже не ждёт оплаты.");
        return;
      }
      if (PAYMENT_SETTLED.includes(order.payment?.status)) {
        sendXml(res, config.checkScript, "rejected", "Заказ уже оплачен.");
        return;
      }
      if (Number(params.pg_amount) !== orderTotal(order)) {
        sendXml(res, config.checkScript, "rejected", "Сумма не совпадает с заказом.");
        return;
      }
      sendXml(res, config.checkScript, "ok", "Можно принимать оплату.");
    } catch (e) {
      // 500, а не «ok»: пусть лучше спросят ещё раз, чем мы молча подтвердим то, чего не знаем.
      console.error("freedompayCheck failed", e);
      res.status(500).send("error");
    }
  },
);

/**
 * Результат платежа.
 *
 * Пишет журнал `payments/{pg_payment_id}` и двигает платёжную ось заказа. Фулфилмент не трогает:
 * это две независимые оси, и фермер начинает работу сам — просто теперь paymentClearsFulfilment
 * его пропустит.
 */
// Сколько заказ может простоять, не двигаясь, прежде чем мы закроем его сами.
//
// Холд — 4 дня, и это НЕ круглое число ради красоты: Freedom Pay списывает неклиренный холд сам
// на пятые сутки. То есть бездействие здесь не безопасно — оно заканчивается списанием денег за
// сделку, которую хозяйство так и не приняло. Сутки запаса нужны, чтобы редкий сбой расписания
// не превратился в списанные деньги.
const HOLD_RELEASE_MS = 4 * 24 * 3600 * 1000;
// Неоплаченный заказ держит доли в лоте: пока он висит, тушу не может купить никто другой.
// Счёт живёт сутки, так что двое суток — это уже заведомо брошенный заказ.
const UNPAID_EXPIRE_MS = 2 * 24 * 3600 * 1000;

/**
 * Закрывает заказы, по которым ничего не происходит: снимает холд, по которому хозяйство так и
 * не приняло заказ, и отпускает доли, занятые неоплаченным заказом.
 *
 * Оба случая возвращают доли в лот — иначе туша остаётся «занятой» человеком, который до неё
 * больше не вернётся.
 */
export const releaseStaleOrders = onSchedule(
  { schedule: "every 2 hours", timeZone: "Asia/Almaty", secrets: [PAY_SECRET] },
  async () => {
    const now = Date.now();
    const waiting = await db.collection("orders").where("status", "==", "created").get();
    let released = 0;

    for (const doc of waiting.docs) {
      const order = doc.data();
      const status = order.payment?.status;
      const since = status === "authorized"
        ? order.payment?.authorizedAt?.toMillis?.()
        : order.createdAt?.toMillis?.();
      const limit = status === "authorized" ? HOLD_RELEASE_MS
        : status === "awaiting" ? UNPAID_EXPIRE_MS
          : null;
      if (!limit || !since || now - since < limit) continue;

      try {
        let intent = null;
        await db.runTransaction(async (tx) => {
          const snap = await tx.get(doc.ref);
          if (!snap.exists) return;
          const fresh = snap.data();
          // Перечитали: за время цикла хозяйство могло принять заказ, а покупатель — оплатить.
          if (stageOf(fresh.status) !== "created" || fresh.payment?.status !== status) return;

          const lotRef = db.collection("lots").doc(String(fresh.lotId || "-"));
          const lotSnap = await tx.get(lotRef);
          const ts = Timestamp.now();

          if (lotSnap.exists) {
            const lot = lotSnap.data();
            const booked = Number(lot.bookedShares) || 0;
            const back = Math.min(Number(fresh.shares) || 0, booked);
            const lotUpdate = { bookedShares: booked - back };
            if (lot.status === "fully_booked" && back > 0) lotUpdate.status = "open";
            tx.update(lotRef, lotUpdate);
          }

          tx.update(doc.ref, {
            status: "cancelled",
            cancelledBy: "system",
            "payment.status": status === "authorized" ? "cancelled" : "expired",
            statusHistory: [...(fresh.statusHistory || []), { status: "cancelled", at: ts, by: "system" }],
            // Плана выплат может и не быть — тогда и отменять в нём нечего.
            ...(fresh.payouts
              ? {
                payouts: payoutPlan(fresh, orderTotal(fresh),
                  { advance: "cancelled", meat: "cancelled", final: "cancelled" }, ts),
              }
              : {}),
            updatedAt: ts,
          });

          notify(tx, {
            to: { uid: fresh.buyerUid, role: "buyer" },
            kind: "order_cancelled",
            title: status === "authorized" ? "Заказ отменён, деньги возвращаются" : "Заказ отменён",
            body: status === "authorized"
              ? `${fresh.lotTitle || "Заказ"}. Хозяйство не приняло его за четыре дня — блокировка с карты снята.`
              : `${fresh.lotTitle || "Заказ"}. Он так и не был оплачен, и туша снова свободна.`,
            link: `/order?id=${doc.id}`,
            orderId: doc.id,
          });

          if (status === "authorized") {
            intent = {
              kind: "release",
              paymentId: String(fresh.payment?.providerPaymentId || ""),
              amount: orderTotal(fresh),
            };
          }
        });

        if (intent) await settleMoney(doc.ref, doc.id, intent);
        released += 1;
      } catch (e) {
        console.error("release failed for order " + doc.id, e);
      }
    }
    if (released) console.log(`released ${released} stale order(s)`);
  },
);

export const freedompayResult = onRequest(
  { invoker: "public", secrets: [PAY_SECRET] },
  async (req, res) => {
    const config = fpConfig();
    const params = callbackParams(req);

    if (!verify(config.resultScript, params, PAY_SECRET.value())) {
      console.warn("freedompayResult: bad signature", params.pg_order_id || "");
      res.status(403).send("bad signature");
      return;
    }

    const paymentId = String(params.pg_payment_id || "");
    const orderId = String(params.pg_order_id || "");
    const canReject = String(params.pg_can_reject || "") === "1";
    if (!paymentId || !orderId) {
      sendXml(res, config.resultScript, "error", "Нет идентификатора платежа или заказа.");
      return;
    }

    try {
      const outcome = await db.runTransaction(async (tx) => {
        const paymentRef = db.collection("payments").doc(paymentId);
        const orderRef = db.collection("orders").doc(orderId);
        const [paymentSnap, orderSnap] = await Promise.all([tx.get(paymentRef), tx.get(orderRef)]);

        // Повтор того же уведомления — не ошибка, а норма протокола: отвечаем как в первый раз.
        if (paymentSnap.exists && paymentSnap.data().result != null) {
          return { status: "ok", description: "Уже учтено." };
        }
        if (!orderSnap.exists) {
          return { status: canReject ? "rejected" : "ok", description: "Заказ не найден." };
        }

        const order = orderSnap.data();
        const total = orderTotal(order);
        const paid = Number(params.pg_amount);
        // Сумму сверяем со своей: принять на рубль меньше — значит подарить разницу.
        if (Number.isFinite(paid) && paid !== total) {
          console.error("freedompayResult: amount mismatch", orderId, paid, total);
          return { status: canReject ? "rejected" : "ok", description: "Сумма не совпадает." };
        }

        const result = Number(params.pg_result);
        const captured = String(params.pg_captured || "") === "1";
        const now = Timestamp.now();

        const update = { updatedAt: now };
        if (result === 1) {
          update["payment.status"] = captured ? "captured_full" : "authorized";
          update["payment.provider"] = "freedompay";
          update["payment.providerPaymentId"] = paymentId;
          update["payment.method"] = String(params.pg_payment_method || "") || null;
          update["payment.authorizedAmount"] = total;
          update["payment.authorizedAt"] = now;
          if (captured) {
            update["payment.capturedAmount"] = total;
            update["payment.capturedAt"] = now;
          }
          update.paidAt = now;
          // Ссылка отработала: держать её дальше незачем.
          update["payment.redirectUrl"] = null;
        } else if (result === 0) {
          update["payment.status"] = "failed";
          update["payment.failureCode"] = String(params.pg_failure_code || "") || null;
        }
        // result === 2 — «не завершён»: ничего не двигаем, платёж ещё в пути.

        if (Object.keys(update).length > 1) tx.update(orderRef, update);

        // Обе стороны узнают об исходе сами. Покупатель мог закрыть браузер, не дождавшись
        // редиректа, а хозяйство иначе увидит оплату, только если само зайдёт в кабинет.
        // Повтор уведомления сюда не доходит — он вышел выше, — поэтому дубля не будет.
        const lot = order.lotTitle || "Заказ";
        if (result === 1) {
          notify(tx, {
            to: { uid: order.partnerId, role: "partner" },
            kind: "order_paid",
            title: "Заказ оплачен",
            // «Оплачен», а не «деньги у нас»: при холде сумма заблокирована на карте и спишется,
            // когда хозяйство примет заказ. Обещать больше, чем есть, на экране про деньги нельзя.
            body: `${lot}. Покупатель оплатил — заказ можно принимать.`,
            link: `/cabinet/order?id=${orderId}`,
            orderId,
          });
          notify(tx, {
            to: { uid: order.buyerUid, role: "buyer" },
            kind: "order_paid",
            title: "Оплата прошла",
            body: `${lot}. Ждём, пока хозяйство примет заказ.`,
            link: `/order?id=${orderId}`,
            orderId,
          });
        } else if (result === 0) {
          notify(tx, {
            to: { uid: order.buyerUid, role: "buyer" },
            kind: "payment_failed",
            title: "Оплата не прошла",
            body: `${lot}. ${String(params.pg_failure_description || "Попробуйте оплатить ещё раз.")}`,
            link: `/order?id=${orderId}`,
            orderId,
          });
        }

        tx.set(paymentRef, {
          provider: "freedompay",
          providerPaymentId: paymentId,
          orderId,
          buyerUid: order.buyerUid || null,
          partnerId: order.partnerId || null,
          amount: Number.isFinite(paid) ? paid : total,
          currency: String(params.pg_currency || order.currency || CURRENCY),
          result,
          captured,
          method: String(params.pg_payment_method || "") || null,
          cardPan: String(params.pg_card_pan || "") || null,
          testing: String(params.pg_testing_mode || "") === "1",
          paymentDate: String(params.pg_payment_date || "") || null,
          failureCode: String(params.pg_failure_code || "") || null,
          createdAt: now,
        });

        return { status: "ok", description: result === 1 ? "Заказ оплачен." : "Результат учтён." };
      });

      sendXml(res, config.resultScript, outcome.status, outcome.description);
    } catch (e) {
      // 500 — чтобы они повторили. Ответить «ok» и потерять запись о деньгах хуже, чем
      // получить то же уведомление ещё раз через полчаса.
      console.error("freedompayResult failed", orderId, e);
      res.status(500).send("error");
    }
  },
);

// =============================================================================================
// Reviews
//
// One review per ORDER - reviews/{orderId}, so a second review of the same deal is impossible -
// and only the buyer of a deal that actually completed may leave one. A farm's rating therefore
// cannot be moved by anyone who never bought from it, and `partners.rating` is recomputed here
// from the published reviews alone (the farm cannot write it - firestore.rules).
//
// Nothing appears in public unmoderated: the team settles disputes by hand at first, and what is
// written about a farm on its page gets the same treatment.
// =============================================================================================
const REVIEW_WINDOW_DAYS = 30;

/** The buyer of a completed deal rates the farm. Waits for moderation; the farm is told then. */
export const submitReview = onCall(CALLABLE, async (request) => {
  const uid = requireRealUser(request.auth);
  const orderId = String(request.data?.orderId || "").trim();
  const rating = Number(request.data?.rating);
  const text = String(request.data?.text || "").trim().slice(0, 1500);
  if (!orderId) throw new HttpsError("invalid-argument", "Не указан заказ.");
  if (!Number.isInteger(rating) || rating < 1 || rating > 5) {
    throw new HttpsError("invalid-argument", "Поставьте оценку от 1 до 5.");
  }

  const orderRef = db.collection("orders").doc(orderId);
  const reviewRef = db.collection("reviews").doc(orderId);

  await db.runTransaction(async (tx) => {
    const [orderSnap, reviewSnap, clientSnap] = await Promise.all([
      tx.get(orderRef), tx.get(reviewRef), tx.get(db.collection("clients").doc(uid)),
    ]);
    if (!orderSnap.exists) throw new HttpsError("not-found", "Заказ не найден.");
    const order = orderSnap.data();
    if (order.buyerUid !== uid) throw new HttpsError("permission-denied", "Отзыв оставляет покупатель этого заказа.");
    if (order.status !== "completed") {
      throw new HttpsError("failed-precondition", "Отзыв можно оставить после завершения сделки.");
    }
    if (reviewSnap.exists) throw new HttpsError("failed-precondition", "Отзыв по этому заказу уже оставлен.");
    // A month is long enough to think it over and short enough that the memory is of this deal.
    const completedAt = order.completedAt?.toMillis?.() || 0;
    if (completedAt && Date.now() - completedAt > REVIEW_WINDOW_DAYS * 86400000) {
      throw new HttpsError("failed-precondition", "Отзыв можно оставить в течение месяца после сделки.");
    }

    const now = Timestamp.now();
    tx.set(reviewRef, {
      orderId,
      lotId: order.lotId || null,
      lotTitle: order.lotTitle || "",
      partnerId: order.partnerId,
      buyerUid: uid,
      buyerName: String(clientSnap.data()?.displayName || "Покупатель").slice(0, 80),
      rating,
      text,
      status: "pending",
      createdAt: now,
      moderatedAt: null,
      moderatedBy: null,
      moderationNote: null,
    });
    tx.update(orderRef, { reviewId: orderId, reviewedAt: now });
  });

  return { status: "pending" };
});

/**
 * Publishes or refuses a review and recomputes the farm's rating from everything published -
 * including, or excluding, this one. The rating and the page always agree because they are
 * written in the same transaction from the same set of reviews.
 */
export const moderateReview = onCall(CALLABLE, async (request) => {
  const actor = await requireStaff(request.auth, "moderate");
  const reviewId = String(request.data?.reviewId || "").trim();
  const { decision, note } = requireDecision(request.data);
  if (!reviewId) throw new HttpsError("invalid-argument", "Не указан отзыв.");

  const ref = db.collection("reviews").doc(reviewId);
  const status = decision === "approve" ? "published" : "rejected";
  let rating = null;
  let pending = [];

  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) throw new HttpsError("not-found", "Отзыв не найден.");
    const review = snap.data();
    const partnerRef = db.collection("partners").doc(String(review.partnerId || "-"));
    // Every read before any write: the farm, and all of its reviews that are public today.
    const [partnerSnap, publishedSnap] = await Promise.all([
      tx.get(partnerRef),
      tx.get(db.collection("reviews")
        .where("partnerId", "==", review.partnerId)
        .where("status", "==", "published")),
    ]);
    const before = review.status || "pending";
    const now = Timestamp.now();

    const others = publishedSnap.docs.filter((d) => d.id !== reviewId).map((d) => Number(d.data().rating) || 0);
    const marks = decision === "approve" ? [...others, Number(review.rating) || 0] : others;
    rating = marks.length ? Math.round((marks.reduce((a, b) => a + b, 0) / marks.length) * 10) / 10 : 0;

    tx.update(ref, { status, moderatedAt: now, moderatedBy: actor.uid, moderationNote: note });
    if (partnerSnap.exists) tx.update(partnerRef, { rating, reviewsCount: marks.length });
    audit(tx, actor, {
      action: "review." + decision,
      targetType: "review",
      targetId: reviewId,
      before: { status: before },
      after: { status, rating },
      note,
    });

    pending = decision === "approve"
      ? [
        {
          to: { uid: review.partnerId, role: "partner" },
          kind: "review_new",
          title: `Новый отзыв — ${review.rating} из 5`,
          body: String(review.text || "").slice(0, 200) || "Покупатель поставил оценку без комментария.",
          link: `/farmers/${review.partnerId}`,
        },
        {
          to: { uid: review.buyerUid, role: "buyer" },
          kind: "review_moderated",
          title: "Ваш отзыв опубликован",
          body: `${review.lotTitle || "Заказ"} · оценка ${review.rating} из 5.`,
          link: `/farmers/${review.partnerId}`,
        },
      ]
      : [{
        to: { uid: review.buyerUid, role: "buyer" },
        kind: "review_moderated",
        title: "Отзыв не опубликован",
        body: `Причина: ${note}`,
        link: `/order?id=${review.orderId}`,
        orderId: review.orderId || null,
      }];
    pending.forEach((n) => notify(tx, n));
  });

  await queueEmails(pending);
  return { status, rating };
});

// =============================================================================================
// Joint purchase - leadership's «складчина», renamed «совместная покупка»
//
// Two to five people split ONE carcass or half: the organiser sets it up (format, cutting,
// delivery, address) and the rest join by the link. The farm hears nothing until the group is
// full - the join that fills the last place creates the order, and from then on it is an ordinary
// order that every participant can follow (orders.memberUids), while the decisions that are the
// buyer's - confirming, disputing, cancelling - stay with the organiser.
//
// Nothing is reserved while a group fills. A held carcass would let anyone block a farm's sale
// for free, and there is no money in the platform yet to hold against it - so a group that fills
// after the carcass is gone simply fails, and says so to everyone in it. When payments arrive,
// each share is taken as its participant joins and the hold arrives with the money.
// =============================================================================================
const GROUP_MIN = 2;
const GROUP_MAX = 5;

/** Even shares, with the odd tenge on the organiser - someone has to carry it. */
function splitAmount(total, size) {
  const each = Math.floor(total / size);
  const parts = new Array(size).fill(each);
  parts[0] = total - each * (size - 1);
  return parts;
}

/** The lot and the farm, checked exactly as an ordinary order checks them. */
async function sellableLot(tx, lotId, format) {
  const lotRef = db.collection("lots").doc(lotId);
  const lotSnap = await tx.get(lotRef);
  if (!lotSnap.exists) throw new HttpsError("not-found", "Лот не найден.");
  const lot = lotSnap.data();
  if (lot.status !== "open") throw new HttpsError("failed-precondition", "Лот сейчас не продаётся.");

  const partnerRef = db.collection("partners").doc(String(lot.partnerId || "-"));
  const partnerSnap = await tx.get(partnerRef);
  if (!partnerSnap.exists || !SELLING_PARTNER_STATUSES.includes(partnerSnap.data().status)) {
    throw new HttpsError("failed-precondition",
      "Хозяйство ещё не прошло проверку платформы — заказ пока недоступен.");
  }

  const total = Number(lot.totalShares) || 0;
  const booked = Number(lot.bookedShares) || 0;
  const shares = sharesFor(lot, format);
  if (format === "half" && !shares) throw new HttpsError("failed-precondition", "Эта туша продаётся только целиком.");
  if (format === "whole" && booked > 0) {
    throw new HttpsError("failed-precondition", "Целиком эту тушу уже не купить — половина забронирована.");
  }
  if (!shares || booked + shares > total) throw new HttpsError("failed-precondition", "Свободной части туши не осталось.");

  return { lotRef, lot, partner: partnerSnap.data(), total, booked, shares };
}

/** Gathers a group: the organiser's own choice, and the places they are waiting to fill. */
export const createGroupBuy = onCall(CALLABLE, async (request) => {
  const uid = requireRealUser(request.auth);
  const data = request.data || {};
  const lotId = String(data.lotId || "").trim();
  const format = String(data.format || "");
  const size = Number(data.size);
  const cuttingId = data.cuttingId ? String(data.cuttingId) : null;
  const deliveryId = data.deliveryId ? String(data.deliveryId) : null;
  const deliveryAddress = String(data.deliveryAddress || "").trim().slice(0, 300);
  const contactPhone = String(data.contactPhone || "").trim().slice(0, 40);
  const deliveryDate = data.deliveryDate ? String(data.deliveryDate) : null;
  const deliverySlot = data.deliverySlot ? String(data.deliverySlot) : null;

  if (!lotId) throw new HttpsError("invalid-argument", "Не указан лот.");
  if (!FORMATS.includes(format)) throw new HttpsError("invalid-argument", "Неизвестный формат заказа.");
  if (!Number.isInteger(size) || size < GROUP_MIN || size > GROUP_MAX) {
    throw new HttpsError("invalid-argument", `Участников совместной покупки может быть от ${GROUP_MIN} до ${GROUP_MAX}.`);
  }
  if (deliverySlot && !DELIVERY_SLOTS.includes(deliverySlot)) {
    throw new HttpsError("invalid-argument", "Некорректное время доставки.");
  }
  if (deliveryDate) checkDeliveryDate(deliveryDate);
  if (contactPhone.length < 6) throw new HttpsError("invalid-argument", "Укажите контактный телефон.");

  const groupRef = db.collection("groupBuys").doc();

  await db.runTransaction(async (tx) => {
    const { lot, partner, shares } = await sellableLot(tx, lotId, format);
    const clientSnap = await tx.get(db.collection("clients").doc(uid));
    if (lot.partnerId === uid) throw new HttpsError("failed-precondition", "Хозяйство не участвует в покупке своей туши.");

    const pricing = priceOrder({ lot, storefront: partner.storefront, format, shares, cuttingId, deliveryId });
    if (pricing.delivery.mode !== "pickup" && deliveryAddress.length < 5) {
      throw new HttpsError("invalid-argument", "Укажите адрес доставки.");
    }
    const now = Timestamp.now();
    const parts = splitAmount(pricing.total, size);
    const name = String(clientSnap.data()?.displayName || "Организатор").slice(0, 80);

    tx.set(groupRef, {
      lotId,
      lotTitle: lot.name || "",
      lotImageUrl: lot.imageUrl || null,
      partnerId: lot.partnerId,
      partnerName: partner.displayName || "",
      format,
      shares,
      size,
      amount: pricing.total,
      perMember: parts,
      pricing: {
        meat: pricing.meat,
        cutting: pricing.cutting ? pricing.cutting.amount : 0,
        delivery: pricing.delivery.amount,
        total: pricing.total,
      },
      estimatedWeightKg: pricing.estimatedWeightKg,
      pricePerKg: pricing.pricePerKg,
      cutting: pricing.cutting,
      cuttingId,
      delivery: pricing.delivery,
      deliveryId,
      deliveryDate,
      deliverySlot,
      creatorUid: uid,
      creatorName: name,
      members: [{ uid, name, amount: parts[0], joinedAt: now }],
      memberUids: [uid],
      status: "open",
      orderId: null,
      createdAt: now,
      updatedAt: now,
    });
    // The address and the organiser's phone are not for everyone holding the link: the group is
    // readable by anyone it is shared with, so the contact details live where only the people in
    // it (and staff) can read them.
    tx.set(groupRef.collection("private").doc("contact"), { deliveryAddress, contactPhone, updatedAt: now });
  });

  return { groupId: groupRef.id };
});

/**
 * Joins a group - and, if this fills the last place, places the order for everyone. The snapshot
 * the participants agreed to is what is ordered: if the farm has changed the price meanwhile, the
 * group fails rather than quietly charging something else.
 */
export const joinGroupBuy = onCall(CALLABLE, async (request) => {
  const uid = requireRealUser(request.auth);
  const groupId = String(request.data?.groupId || "").trim();
  if (!groupId) throw new HttpsError("invalid-argument", "Не указана совместная покупка.");

  const groupRef = db.collection("groupBuys").doc(groupId);
  let result = null;
  let pending = [];

  await db.runTransaction(async (tx) => {
    const groupSnap = await tx.get(groupRef);
    if (!groupSnap.exists) throw new HttpsError("not-found", "Совместная покупка не найдена.");
    const group = groupSnap.data();
    if (group.status !== "open") throw new HttpsError("failed-precondition", "Эта совместная покупка уже закрыта.");
    if ((group.memberUids || []).includes(uid)) throw new HttpsError("failed-precondition", "Вы уже участвуете.");
    if (group.partnerId === uid) throw new HttpsError("failed-precondition", "Хозяйство не участвует в покупке своей туши.");
    const members = Array.isArray(group.members) ? group.members : [];
    if (members.length >= group.size) throw new HttpsError("failed-precondition", "Все места уже заняты.");

    const clientSnap = await tx.get(db.collection("clients").doc(uid));
    const now = Timestamp.now();
    const name = String(clientSnap.data()?.displayName || "Участник").slice(0, 80);
    const joined = [...members, { uid, name, amount: (group.perMember || [])[members.length] || 0, joinedAt: now }];
    const full = joined.length >= group.size;

    if (!full) {
      tx.update(groupRef, { members: joined, memberUids: joined.map((m) => m.uid), updatedAt: now });
      // Only the organiser is waiting for this; the rest see it when they open the page.
      pending = [{
        to: { uid: group.creatorUid, role: "buyer" },
        kind: "group_joined",
        title: "К совместной покупке присоединились",
        body: `${name} · собрано ${joined.length} из ${group.size}.`,
        link: `/group?id=${groupId}`,
        groupId,
      }];
      pending.forEach((n) => notify(tx, n));
      result = { status: "open", joined: joined.length, size: group.size };
      return;
    }

    // The last place: the order goes to the farm now. Everything is read before anything is
    // written - the lot, the farm, the organiser's contact details and their purchase mirror.
    const contactSnap = await tx.get(groupRef.collection("private").doc("contact"));
    let lotState;
    try {
      lotState = await sellableLot(tx, String(group.lotId), String(group.format));
    } catch (e) {
      // The carcass went while the group was filling. Nothing was held, so nothing is lost -
      // but everyone hears it from us rather than finding an order that never appeared.
      tx.update(groupRef, {
        members: joined, memberUids: joined.map((m) => m.uid), status: "failed",
        failedReason: e?.message || "Туша больше не доступна.", updatedAt: now,
      });
      pending = joined.map((m) => ({
        to: { uid: m.uid, role: "buyer" },
        kind: "group_failed",
        title: "Совместная покупка не состоялась",
        body: `${group.lotTitle || "Туша"} — ${e?.message || "туша больше не доступна"}. Деньги никто не вносил.`,
        link: `/group?id=${groupId}`,
        groupId,
      }));
      pending.forEach((n) => notify(tx, n));
      result = { status: "failed" };
      return;
    }

    const { lotRef, lot, partner, total, booked, shares } = lotState;
    const pricing = priceOrder({
      lot, storefront: partner.storefront, format: group.format, shares,
      cuttingId: group.cuttingId || null, deliveryId: group.deliveryId || null,
    });
    if (pricing.total !== Number(group.amount)) {
      throw new HttpsError("failed-precondition",
        "Хозяйство изменило цену или условия — соберите совместную покупку заново.");
    }

    const orderRef = db.collection("orders").doc();
    const purchaseRef = db.collection("clients").doc(String(group.creatorUid)).collection("purchases").doc(String(group.lotId));
    const purchaseSnap = await tx.get(purchaseRef);
    const contact = contactSnap.data() || {};

    writeOrder(tx, {
      orderRef, lotRef, lot, lotId: String(group.lotId), booked, total, shares, pricing,
      format: group.format, now,
      buyerUid: group.creatorUid,
      buyerPhone: null,
      contactPhone: contact.contactPhone || "",
      deliveryAddress: contact.deliveryAddress || "",
      deliveryDate: group.deliveryDate || null,
      deliverySlot: group.deliverySlot || null,
      purchaseRef, purchaseSnap,
      group: {
        id: groupId,
        size: group.size,
        members: joined.map((m) => ({ uid: m.uid, name: m.name, amount: m.amount })),
      },
    });
    tx.update(groupRef, {
      members: joined, memberUids: joined.map((m) => m.uid),
      status: "placed", orderId: orderRef.id, placedAt: now, updatedAt: now,
    });

    pending = [
      {
        to: { uid: lot.partnerId, role: "partner" },
        kind: "order_new",
        title: "Новый заказ — совместная покупка",
        body: `${lot.name || "Лот"} · ${FORMAT_LABEL[group.format]} · ${group.size} ${pluralRu(group.size, "участник", "участника", "участников")} · ${tenge(pricing.total)}`,
        link: `/cabinet/order?id=${orderRef.id}`,
        orderId: orderRef.id,
      },
      ...joined.map((m) => ({
        to: { uid: m.uid, role: "buyer" },
        kind: "group_ready",
        title: "Совместная покупка собрана",
        body: `${group.lotTitle || "Туша"} · ваша доля ${tenge(m.amount)}. Заказ ушёл хозяйству.`,
        link: `/order?id=${orderRef.id}`,
        orderId: orderRef.id,
      })),
    ];
    pending.forEach((n) => notify(tx, n));
    result = { status: "placed", orderId: orderRef.id };
  });

  await queueEmails(pending);
  return result;
});

/**
 * Leaves a group, or - for the organiser - calls the whole thing off. Only possible while the
 * group is still filling: once the order exists it is the order's own cancel that applies.
 */
export const leaveGroupBuy = onCall(CALLABLE, async (request) => {
  const uid = requireRealUser(request.auth);
  const groupId = String(request.data?.groupId || "").trim();
  if (!groupId) throw new HttpsError("invalid-argument", "Не указана совместная покупка.");

  const groupRef = db.collection("groupBuys").doc(groupId);
  let result = null;
  let pending = [];

  await db.runTransaction(async (tx) => {
    const snap = await tx.get(groupRef);
    if (!snap.exists) throw new HttpsError("not-found", "Совместная покупка не найдена.");
    const group = snap.data();
    if (group.status !== "open") throw new HttpsError("failed-precondition", "Эта совместная покупка уже закрыта.");
    const members = Array.isArray(group.members) ? group.members : [];
    if (!members.some((m) => m.uid === uid)) throw new HttpsError("permission-denied", "Вы не участвуете в этой покупке.");

    const now = Timestamp.now();
    if (uid === group.creatorUid) {
      tx.update(groupRef, { status: "cancelled", cancelledAt: now, updatedAt: now });
      pending = members.filter((m) => m.uid !== uid).map((m) => ({
        to: { uid: m.uid, role: "buyer" },
        kind: "group_failed",
        title: "Совместная покупка отменена",
        body: `${group.lotTitle || "Туша"} — организатор отменил сбор.`,
        link: `/group?id=${groupId}`,
        groupId,
      }));
      pending.forEach((n) => notify(tx, n));
      result = { status: "cancelled" };
      return;
    }

    const left = members.filter((m) => m.uid !== uid);
    tx.update(groupRef, { members: left, memberUids: left.map((m) => m.uid), updatedAt: now });
    pending = [{
      to: { uid: group.creatorUid, role: "buyer" },
      kind: "group_joined",
      title: "Участник вышел из совместной покупки",
      body: `Собрано ${left.length} из ${group.size}.`,
      link: `/group?id=${groupId}`,
        groupId,
    }];
    pending.forEach((n) => notify(tx, n));
    result = { status: "open", joined: left.length, size: group.size };
  });

  await queueEmails(pending);
  return result;
});

// =============================================================================================
// Staff (administrators)
//
// A staff member is identified by a CUSTOM CLAIM `role` on their Firebase token, set only here
// through the Admin SDK - a client cannot forge it. Roles rather than a bare admin flag, so the
// panel can later split into moderators and support without changing the claim's shape:
//
//   admin    - everything, including granting and revoking staff
//   support  - watch the platform and act on orders; cannot approve partners or documents
//
// A claim alone is not enough, because it lives inside the ID token and survives for up to an
// hour after being revoked. So every staff action ALSO requires a staff/{uid} document, which
// revocation deletes at once. The rules check the same document, so reads stop immediately too.
// =============================================================================================
const STAFF_PERMISSIONS = {
  admin: new Set(["staff.manage", "moderate", "orders.act", "view"]),
  support: new Set(["orders.act", "view"]),
};

/** The phones allowed to make THEMSELVES admin before any admin exists. From functions/.env. */
function bootstrapPhones() {
  return String(process.env.BOOTSTRAP_ADMIN_PHONES || "")
    .split(",").map((p) => p.trim()).filter(Boolean);
}

function normalisePhone(raw) {
  const digits = String(raw || "").replace(/[^\d+]/g, "");
  if (digits.startsWith("+")) return digits;
  if (digits.startsWith("8") && digits.length === 11) return "+7" + digits.slice(1);
  if (digits.startsWith("7")) return "+" + digits;
  return digits ? "+7" + digits : "";
}

/**
 * Verifies the caller is live staff holding `permission`. Returns who they are, for the audit
 * trail. Throws otherwise - with the same message whether the role is missing or merely lacks
 * the permission, so the response does not help anyone map out the roles.
 */
async function requireStaff(auth, permission) {
  const uid = requireRealUser(auth);
  const role = auth.token?.role;
  const deny = () => { throw new HttpsError("permission-denied", "Нет доступа."); };
  if (!STAFF_PERMISSIONS[role]?.has(permission)) deny();
  const staffDoc = await db.collection("staff").doc(uid).get();
  if (!staffDoc.exists || staffDoc.data().role !== role) deny();
  return { uid, role, phone: auth.token?.phone_number || null };
}

/**
 * Every staff decision leaves a record: who, what, on what, before and after, and why. Written
 * in the SAME transaction as the change it describes, so there is no path to one without the
 * other. Nobody can edit or delete these - not even an admin (see firestore.rules).
 */
function audit(tx, actor, entry) {
  tx.set(db.collection("adminActions").doc(), {
    actorUid: actor.uid,
    actorRole: actor.role,
    actorPhone: actor.phone,
    at: Timestamp.now(),
    note: null,
    before: null,
    after: null,
    ...entry,
  });
}

/**
 * Grants a staff role to the account registered with `phone`.
 *
 * Two ways in:
 *   - the caller is already an admin, or
 *   - bootstrap: nobody is admin yet, so the owner's own verified phone, listed server-side in
 *     BOOTSTRAP_ADMIN_PHONES, may make ITSELF admin. Nothing else - not another number, not
 *     another role. The phone is proven by OTP, so only whoever holds that SIM can do it, and no
 *     service-account key ever has to leave Google.
 */
export const grantStaffRole = onCall(CALLABLE, async (request) => {
  const auth = request.auth;
  const callerUid = requireRealUser(auth);
  const role = String(request.data?.role || "admin");
  const phone = normalisePhone(request.data?.phone);
  if (!STAFF_PERMISSIONS[role]) throw new HttpsError("invalid-argument", "Неизвестная роль.");
  if (!/^\+\d{10,15}$/.test(phone)) throw new HttpsError("invalid-argument", "Некорректный номер.");

  const callerPhone = auth.token?.phone_number || null;
  let actor = null;
  let bootstrap = false;
  try {
    actor = await requireStaff(auth, "staff.manage");
  } catch (_) {
    bootstrap = role === "admin" && phone === callerPhone && bootstrapPhones().includes(callerPhone);
    if (!bootstrap) throw new HttpsError("permission-denied", "Нет доступа.");
    actor = { uid: callerUid, role: "bootstrap", phone: callerPhone };
  }

  // The person has to have signed in once, so an account exists to put the claim on.
  const user = await findUserByPhone(phone);

  const previousRole = user.customClaims?.role || null;
  await getAuth().setCustomUserClaims(user.uid, { ...(user.customClaims || {}), role });

  await db.runTransaction(async (tx) => {
    tx.set(db.collection("staff").doc(user.uid), {
      uid: user.uid,
      phone,
      role,
      grantedBy: actor.uid,
      grantedAt: Timestamp.now(),
    });
    audit(tx, actor, {
      action: bootstrap ? "staff.bootstrap" : "staff.grant",
      targetType: "staff",
      targetId: user.uid,
      before: { role: previousRole },
      after: { role, phone },
    });
  });

  // The new claim only reaches the browser on the next token refresh; the panel forces one.
  return { uid: user.uid, role, bootstrap };
});

/**
 * Removes a staff role. Deleting staff/{uid} cuts off every action and read at once; revoking
 * refresh tokens makes their sessions re-authenticate instead of quietly minting a fresh token
 * that still carries the old claim.
 */
export const revokeStaffRole = onCall(CALLABLE, async (request) => {
  const actor = await requireStaff(request.auth, "staff.manage");
  const phone = normalisePhone(request.data?.phone);
  if (phone === actor.phone) {
    // Otherwise the last admin can lock the whole platform out of its own panel.
    throw new HttpsError("failed-precondition", "Нельзя снять права с самого себя.");
  }

  // The person has to have signed in once, so an account exists to put the claim on.
  const user = await findUserByPhone(phone);

  const claims = { ...(user.customClaims || {}) };
  const previousRole = claims.role || null;
  delete claims.role;
  await getAuth().setCustomUserClaims(user.uid, claims);
  await getAuth().revokeRefreshTokens(user.uid);

  await db.runTransaction(async (tx) => {
    tx.delete(db.collection("staff").doc(user.uid));
    audit(tx, actor, {
      action: "staff.revoke",
      targetType: "staff",
      targetId: user.uid,
      before: { role: previousRole, phone },
      after: { role: null },
    });
  });
  return { uid: user.uid };
});

/**
 * Looks an account up by phone. Only a genuine auth/user-not-found means "this person has never
 * signed in". Every other failure is the SERVER's problem - most likely the runtime service
 * account lacking Firebase Authentication Admin - and must be logged, not dressed up as the
 * caller's mistake. Reporting every error as "not found" once told the owner that the very number
 * they were signed in with had never signed in, and left nothing in the logs to say why.
 */
async function findUserByPhone(phone) {
  try {
    return await getAuth().getUserByPhoneNumber(phone);
  } catch (e) {
    if (e?.code === "auth/user-not-found") {
      throw new HttpsError("not-found", "Этот номер ещё ни разу не входил на сайт или в приложение.");
    }
    console.error("getUserByPhoneNumber failed for a reason other than not-found", e);
    throw new HttpsError("internal",
      "Сервер не смог проверить аккаунт. Скорее всего, у сервисного аккаунта функций нет роли Firebase Authentication Admin.");
  }
}

const DECISIONS = new Set(["approve", "reject"]);

function requireDecision(data) {
  const decision = String(data?.decision || "");
  const note = String(data?.note || "").trim().slice(0, 500);
  if (!DECISIONS.has(decision)) throw new HttpsError("invalid-argument", "Неизвестное решение.");
  // A rejection with no reason is useless to the farmer, who sees this text in their cabinet.
  if (decision === "reject" && note.length < 5) {
    throw new HttpsError("invalid-argument", "Укажите причину отказа — её увидит фермер.");
  }
  return { decision, note: note || null };
}

/** Approves or rejects a farm. Only this path can move partners/{uid}.status - see the rules. */
export const reviewPartner = onCall(CALLABLE, async (request) => {
  const actor = await requireStaff(request.auth, "moderate");
  const partnerId = String(request.data?.partnerId || "").trim();
  const { decision, note } = requireDecision(request.data);
  if (!partnerId) throw new HttpsError("invalid-argument", "Не указано хозяйство.");

  const ref = db.collection("partners").doc(partnerId);
  const status = decision === "approve" ? "verified" : "rejected";
  let pending = [];
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) throw new HttpsError("not-found", "Хозяйство не найдено.");
    const before = snap.data().status || null;
    const now = Timestamp.now();
    // The reason goes to the farm's private record, not onto its public profile: the profile is
    // readable by every visitor, and "справки просрочены" is between the farm and the platform.
    // Fields an earlier version left on the profile are removed on the next decision.
    tx.update(ref, { status, reviewedAt: now, reviewedBy: FieldValue.delete(), reviewNote: FieldValue.delete() });
    tx.set(ref.collection("private").doc("review"), { decision, note, decidedAt: now, decidedBy: actor.uid });
    audit(tx, actor, {
      action: "partner." + decision,
      targetType: "partner",
      targetId: partnerId,
      before: { status: before },
      after: { status },
      note,
    });
    pending = [{
      to: { uid: partnerId, role: "partner" },
      kind: "farm_review",
      title: decision === "approve" ? "Хозяйство прошло проверку" : "Хозяйство не допущено к продажам",
      body: decision === "approve"
        ? "Лоты видны покупателям, заказы принимаются."
        : `Причина: ${note}`,
      link: "/cabinet/lots",
    }];
    pending.forEach((n) => notify(tx, n));
  });
  await queueEmails(pending);
  return { status };
});

/**
 * Удаляет лот от имени сотрудника.
 *
 * Хозяйство удаляет свои лоты само, но правила не дают ему тронуть лот, в котором есть брони:
 * иначе из каталога исчезла бы туша, за которую уже заплатили. Сотруднику нужен путь именно для
 * таких случаев — тестовый лот, лот с чужой фотографией, лот, который фермер бросил.
 *
 * Заказы при этом остаются жить, и это проверено: все серверные пути, читающие лот, —
 * `cancel` в updateOrderStatus, ночной releaseStaleOrders, выбор животного — обёрнуты в
 * `lotSnap.exists`. Создать НОВЫЙ заказ на удалённый лот нельзя: createOrder бросает not-found.
 */
export const deleteLot = onCall(CALLABLE, async (request) => {
  const actor = await requireStaff(request.auth, "moderate");
  const lotId = String(request.data?.lotId || "").trim();
  const force = request.data?.force === true;
  if (!lotId) throw new HttpsError("invalid-argument", "Не указан лот.");

  const ref = db.collection("lots").doc(lotId);
  const snap = await ref.get();
  if (!snap.exists) throw new HttpsError("not-found", "Лот не найден.");
  const lot = snap.data();
  const booked = Number(lot.bookedShares) || 0;

  // Лот с бронями удаляется только вторым, осознанным нажатием. Отказ здесь — не запрет, а
  // остановка: панель покажет, сколько долей занято, и спросит ещё раз.
  if (booked > 0 && !force) {
    throw new HttpsError(
      "failed-precondition",
      `В лоте занято ${booked} ${booked === 1 ? "доля" : "долей"} — подтвердите удаление.`,
    );
  }

  // Шаги доставки живут под лотом и без него бессмысленны.
  const steps = await ref.collection("deliveries").get();
  const batch = db.batch();
  steps.docs.forEach((d) => batch.delete(d.ref));
  batch.delete(ref);
  // audit() пишет через tx.set, а у WriteBatch тот же set — запись в журнал уходит тем же
  // коммитом, что и удаление. Одного без другого не бывает.
  audit(batch, actor, {
    action: "lot.delete",
    targetType: "lot",
    targetId: lotId,
    before: {
      name: lot.name || null,
      partnerId: lot.partnerId || null,
      status: lot.status || null,
      totalShares: Number(lot.totalShares) || 0,
      bookedShares: booked,
      deliveries: steps.size,
    },
    after: null,
    note: booked > 0 ? `Удалён лот с ${booked} занятыми долями — заказы на него остались` : null,
  });
  await batch.commit();
  return { ok: true, deletedSteps: steps.size, bookedShares: booked };
});

// ---------------------------------------------------------------------------------------------
// Hub location
//
// A farm's exact point stays private (partners/{uid}/private/location: the farm and staff) and
// buyers see a point snapped to a ~5 km grid. Both are written here, in one transaction, so the
// public point is always derived from the private one - never supplied by the client.
// ---------------------------------------------------------------------------------------------

const PUBLIC_CELL_KM = 5;
const KM_PER_DEGREE_LAT = 111.32;
// Kazakhstan's extremes, padded slightly. A box, not the border, so a point just across it passes
// - the region the farm names and the staff review catch that; this catches typos and (0, 0).
const KZ_BOUNDS = { minLat: 40.4, maxLat: 55.6, minLng: 46.3, maxLng: 87.5 };

const round = (n, digits) => Math.round(n * 10 ** digits) / 10 ** digits;

/**
 * The public stand-in for an exact point: the centre of its cell on a grid of ~5 km squares.
 * A grid, not random noise - noise re-drawn on every save could be averaged back to the exact
 * point, while a cell centre never moves. At most ~3.5 km (half a cell diagonal) from the truth.
 */
function publicPoint(lat, lng) {
  const dLat = PUBLIC_CELL_KM / KM_PER_DEGREE_LAT;
  const cellLat = (Math.floor(lat / dLat) + 0.5) * dLat;
  // Longitude degrees shrink towards the pole; the row's own latitude sets the cell width, so a
  // cell stays roughly square and every point in the row maps the same way.
  const dLng = PUBLIC_CELL_KM / (KM_PER_DEGREE_LAT * Math.cos((cellLat * Math.PI) / 180));
  const cellLng = (Math.floor(lng / dLng) + 0.5) * dLng;
  return { lat: round(cellLat, 4), lng: round(cellLng, 4), precisionKm: PUBLIC_CELL_KM };
}

/**
 * Sets or clears the caller's own hub point. Data: { lat, lng } or { clear: true }.
 * Only a farm's owner can place it; staff see it but do not move it.
 */
export const setHubLocation = onCall(CALLABLE, async (request) => {
  const uid = requireRealUser(request.auth);
  const clear = request.data?.clear === true;

  let exact = null;
  if (!clear) {
    const lat = Number(request.data?.lat);
    const lng = Number(request.data?.lng);
    const inside = Number.isFinite(lat) && Number.isFinite(lng)
      && lat >= KZ_BOUNDS.minLat && lat <= KZ_BOUNDS.maxLat
      && lng >= KZ_BOUNDS.minLng && lng <= KZ_BOUNDS.maxLng;
    if (!inside) throw new HttpsError("invalid-argument", "Точка должна быть на территории Казахстана.");
    exact = { lat: round(lat, 6), lng: round(lng, 6) };
  }

  const ref = db.collection("partners").doc(uid);
  const privateRef = ref.collection("private").doc("location");
  const shown = exact ? publicPoint(exact.lat, exact.lng) : null;

  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) throw new HttpsError("failed-precondition", "Сначала зарегистрируйте хозяйство.");
    const now = Timestamp.now();
    if (exact) tx.set(privateRef, { ...exact, updatedAt: now });
    else tx.delete(privateRef);
    tx.update(ref, { publicLocation: shown, locationUpdatedAt: now });
  });
  return { publicLocation: shown };
});

// A farm counts as certified when both of these are approved - what leadership's catalogue shows as
// the certification badge.
const CERTIFYING_KINDS = ["ses", "vet_control"];

/**
 * Approves or rejects one document: a veterinary certificate on an animal ({ animalId, docId }) or
 * one of the farm's own certificates ({ partnerId, docId }). The only way a document's status can
 * change - and, for a farm's own, the only way its public `certified` badge moves, recomputed here
 * from all of its certificates in the same transaction.
 */
export const reviewDocument = onCall(CALLABLE, async (request) => {
  const actor = await requireStaff(request.auth, "moderate");
  const animalId = String(request.data?.animalId || "").trim();
  const partnerId = String(request.data?.partnerId || "").trim();
  const docId = String(request.data?.docId || "").trim();
  const { decision, note } = requireDecision(request.data);
  if (!docId || (!animalId && !partnerId)) throw new HttpsError("invalid-argument", "Не указан документ.");

  const farmDoc = !animalId;
  const partnerRef = farmDoc ? db.collection("partners").doc(partnerId) : null;
  const ref = farmDoc
    ? partnerRef.collection("documents").doc(docId)
    : db.collection("animals").doc(animalId).collection("documents").doc(docId);
  const status = decision === "approve" ? "approved" : "rejected";
  let certified = null;
  let pending = [];

  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) throw new HttpsError("not-found", "Документ не найден.");
    // Every read before any write.
    const siblings = farmDoc ? await tx.get(partnerRef.collection("documents")) : null;
    const before = snap.data().status || null;
    const now = Timestamp.now();

    tx.update(ref, { status, reviewedAt: now, reviewedBy: actor.uid, reviewNote: note });
    if (farmDoc) {
      const approved = new Set(siblings.docs
        .map((d) => (d.id === docId ? { ...d.data(), status } : d.data()))
        .filter((d) => d.status === "approved")
        .map((d) => d.kind));
      certified = CERTIFYING_KINDS.every((k) => approved.has(k));
      tx.update(partnerRef, { certified });
    }
    audit(tx, actor, {
      action: "document." + decision,
      targetType: "document",
      targetId: farmDoc ? `farm:${partnerId}/${docId}` : animalId + "/" + docId,
      before: { status: before },
      after: { status },
      note,
    });
    // Whose paperwork this is: the farm's own certificate, or a vet document on its animal.
    const owner = farmDoc ? partnerId : snap.data().partnerId;
    const label = String(snap.data().label || "Документ");
    if (owner) {
      pending = [{
        to: { uid: owner, role: "partner" },
        kind: "document_review",
        title: decision === "approve" ? "Документ принят" : "Документ отклонён",
        body: decision === "approve"
          ? `${label}.${certified ? " Хозяйство отмечено как сертифицированное." : ""}`
          : `${label}. Причина: ${note}`,
        link: farmDoc ? "/cabinet/storefront" : "/cabinet/animals",
      }];
      pending.forEach((n) => notify(tx, n));
    }
  });
  await queueEmails(pending);
  return { status, certified };
});

// ---------------------------------------------------------------------------------------------
// Disputes
//
// A buyer files one from the order page (disputes/{id}: uid, lotId, description, mediaUrl,
// status 'new'). For now the team settles them by hand - any refund included, outside the
// platform - so this records who took the case, what was decided and why, and nothing else moves.
//
//   new -> in_review -> resolved      (take the case, then close it)
//   new -> resolved                   (close it straight away)
//
// The decision's note is shown to the buyer on their order page, so closing requires one.
// ---------------------------------------------------------------------------------------------
const DISPUTE_OUTCOMES = new Set(["buyer", "partner", "partial", "withdrawn"]);

export const reviewDispute = onCall(CALLABLE, async (request) => {
  const actor = await requireStaff(request.auth, "orders.act");
  const disputeId = String(request.data?.disputeId || "").trim();
  const action = String(request.data?.action || "");
  const note = String(request.data?.note || "").trim().slice(0, 1000);
  if (!disputeId) throw new HttpsError("invalid-argument", "Не указан спор.");
  if (action !== "take" && action !== "resolve") throw new HttpsError("invalid-argument", "Неизвестное действие.");

  let outcome = null;
  if (action === "resolve") {
    outcome = String(request.data?.outcome || "");
    if (!DISPUTE_OUTCOMES.has(outcome)) throw new HttpsError("invalid-argument", "Выберите решение по спору.");
    if (note.length < 5) throw new HttpsError("invalid-argument", "Опишите решение — его увидит покупатель.");
  }

  const ref = db.collection("disputes").doc(disputeId);
  let status = null;
  let pending = [];
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) throw new HttpsError("not-found", "Спор не найден.");
    const dispute = snap.data();
    const before = dispute.status || "new";
    const now = Timestamp.now();
    // A dispute opened from an order holds that order's last payout; closing the dispute closes
    // the order too. Read before any write.
    const orderRef = dispute.orderId ? db.collection("orders").doc(String(dispute.orderId)) : null;
    const orderSnap = orderRef ? await tx.get(orderRef) : null;

    if (action === "take") {
      if (before !== "new") throw new HttpsError("failed-precondition", "Спор уже взят в работу или закрыт.");
      status = "in_review";
      tx.update(ref, { status, handledBy: actor.uid, takenAt: now, updatedAt: now });
    } else {
      if (before === "resolved") throw new HttpsError("failed-precondition", "Спор уже закрыт.");
      status = "resolved";
      tx.update(ref, {
        status,
        handledBy: actor.uid,
        updatedAt: now,
        resolution: { outcome, note, decidedAt: now, decidedBy: actor.uid },
      });
      // In the farm's favour - or the buyer took the claim back - the last part is released;
      // otherwise it is withheld, and any refund is made by hand for now.
      const forFarm = outcome === "partner" || outcome === "withdrawn";
      if (orderSnap?.exists && orderSnap.data().status === "disputed") {
        const order = orderSnap.data();
        tx.update(orderRef, {
          ...completionUpdate(order, now, "dispute", forFarm ? "unlocked" : "withheld"),
          disputeOutcome: outcome,
          statusHistory: [...(order.statusHistory || []), { status: "completed", at: now, by: actor.uid }],
          updatedAt: now,
        });
        if (forFarm) {
          tx.update(db.collection("partners").doc(String(order.partnerId || "-")), { totalDeals: FieldValue.increment(1) });
        }
      }

      // Both sides hear the decision: the buyer in the moderator's own words, the farm in terms
      // of the money it was waiting on.
      pending = [{
        to: { uid: dispute.uid, role: "buyer" },
        kind: "dispute_resolved",
        title: "Спор закрыт",
        body: note,
        link: dispute.orderId ? `/order?id=${dispute.orderId}` : "/orders",
        orderId: dispute.orderId || null,
      }];
      if (dispute.partnerId) {
        pending.push({
          to: { uid: dispute.partnerId, role: "partner" },
          kind: "dispute_resolved",
          title: "Спор закрыт",
          body: forFarm
            ? "Решение в пользу хозяйства — последняя выплата открыта."
            : "Решение в пользу покупателя — последняя выплата удержана.",
          link: dispute.orderId ? `/cabinet/order?id=${dispute.orderId}` : "/cabinet/orders",
          orderId: dispute.orderId || null,
        });
      }
      pending.forEach((n) => notify(tx, n));
    }

    audit(tx, actor, {
      action: "dispute." + action,
      targetType: "dispute",
      targetId: disputeId,
      before: { status: before },
      after: outcome ? { status, outcome } : { status },
      note: note || null,
    });
  });
  await queueEmails(pending);
  return { status };
});

// =============================================================================================
// Удаление аккаунта
//
// Google Play требует, чтобы человек мог удалить аккаунт из самого приложения, а не только
// письмом в поддержку. Здесь это делается по правилам, которые важнее удобства:
//
//   - НЕЗАВЕРШЁННАЯ СДЕЛКА НЕ УДАЛЯЕТСЯ. Пока заказ идёт, у него две стороны: хозяйство готовит
//     тушу, покупатель ждёт мясо. Стереть одну сторону посреди этого - значит оставить вторую
//     с заказом, у которого нет собеседника. Поэтому сначала заказ закрывают или отменяют.
//   - ЗАКРЫТЫЕ ЗАКАЗЫ ОСТАЮТСЯ. Это запись о деньгах и о том, что произошло, и она принадлежит
//     обеим сторонам, а не одной. Убирается из неё только личное: телефон и адрес.
//   - ОТЗЫВЫ ОСТАЮТСЯ БЕЗ ИМЕНИ. Рейтинг хозяйства сложился из них; удалить отзыв задним числом
//     - это переписать чужую репутацию. Имя заменяется на «Покупатель».
//
// Всё остальное - профиль, корзина, телефоны для push, приватные записи, уведомления - стирается,
// и следом удаляется сам аккаунт входа: вернуться под тем же номером можно, но это будет новый
// человек с чистого листа.
// =============================================================================================

/** Applies one write to many documents, 400 at a time - a person can have hundreds of notifications. */
async function commitInBatches(docs, apply) {
  for (let i = 0; i < docs.length; i += 400) {
    const batch = db.batch();
    for (const doc of docs.slice(i, i + 400)) apply(batch, doc);
    await batch.commit();
  }
}

/** Everything under a person's record: cart, devices, private, purchases. */
async function deleteSubcollections(ref) {
  for (const collection of await ref.listCollections()) {
    const snap = await collection.get();
    await commitInBatches(snap.docs, (batch, doc) => batch.delete(doc.ref));
  }
}

export const deleteMyAccount = onCall(CALLABLE, async (request) => {
  const uid = requireRealUser(request.auth);
  const role = request.data?.role === "partner" ? "partner" : "buyer";
  const mineField = role === "partner" ? "partnerId" : "buyerUid";

  // Everything is read by ONE equality field and filtered here, on purpose: a compound query
  // would want a composite index of its own, and an index that exists only for the rarest
  // operation on the platform is an index nobody will remember to deploy. A person's orders are
  // counted in tens.
  const mine = await db.collection("orders").where(mineField, "==", uid).get();
  const unfinished = (docs) => docs.filter((d) => !FINISHED_STATUSES.includes(String(d.data().status || "")));

  if (unfinished(mine.docs).length) {
    throw new HttpsError(
      "failed-precondition",
      role === "partner"
        ? "Есть незакрытые заказы. Завершите или отмените их — после этого аккаунт можно удалить."
        : "Есть незакрытый заказ. Дождитесь получения или отмените заказ — после этого аккаунт можно удалить.",
    );
  }

  let shared = { docs: [] };
  if (role === "buyer") {
    shared = await db.collection("orders").where("memberUids", "array-contains", uid).get();
    if (unfinished(shared.docs).length) {
      throw new HttpsError("failed-precondition",
        "Вы участник незакрытой совместной покупки. Дождитесь её завершения — после этого аккаунт можно удалить.");
    }

    const groups = await db.collection("groupBuys").where("memberUids", "array-contains", uid).get();
    if (groups.docs.some((d) => d.data().status === "open")) {
      throw new HttpsError("failed-precondition",
        "Идёт сбор совместной покупки с вашим участием. Выйдите из него или отмените сбор — после этого аккаунт можно удалить.");
    }
  }

  let lots = { docs: [] };
  let animals = { docs: [] };
  if (role === "partner") {
    lots = await db.collection("lots").where("partnerId", "==", uid).get();
    if (lots.docs.some((d) => Number(d.data().bookedShares || 0) > 0)) {
      throw new HttpsError("failed-precondition",
        "На ваши туши есть брони. Закройте сделки по ним — после этого аккаунт можно удалить.");
    }
    animals = await db.collection("animals").where("partnerId", "==", uid).get();
  }

  const disputes = await db.collection("disputes")
    .where(role === "partner" ? "partnerId" : "uid", "==", uid).get();
  if (disputes.docs.some((d) => ["new", "in_review"].includes(String(d.data().status || "")))) {
    throw new HttpsError("failed-precondition",
      "По вашему спору ещё не вынесено решение. Дождитесь его — после этого аккаунт можно удалить.");
  }

  // ---- what is left of the person ---------------------------------------------------------------
  const ownerRef = db.collection(role === "partner" ? "partners" : "clients").doc(uid);

  // Closed orders stay as the record of the deal - they belong to both sides. Only the personal
  // part of them goes, and only the part that is THIS person's: on a joint purchase the address
  // and the phone belong to whoever placed it, so a leaving participant loses their name and
  // nothing else.
  const now = Timestamp.now();
  await commitInBatches(mine.docs, (batch, doc) => batch.update(doc.ref, role === "partner"
    ? { partnerDeletedAt: now }
    : { contactPhone: null, buyerPhone: null, deliveryAddress: null, buyerDeletedAt: now }));

  const asMember = shared.docs.filter((d) => d.data().buyerUid !== uid);
  await commitInBatches(asMember, (batch, doc) => {
    const group = doc.data().group || {};
    const members = (group.members || []).map((m) => (m && m.uid === uid
      ? { ...m, name: "Участник", deletedAt: now }
      : m));
    batch.update(doc.ref, { "group.members": members });
  });

  // Reviews made the farm's rating; deleting them would rewrite someone else's reputation. The
  // name goes, the words stay.
  if (role === "buyer") {
    const reviews = await db.collection("reviews").where("buyerUid", "==", uid).get();
    await commitInBatches(reviews.docs, (batch, doc) => batch.update(doc.ref, {
      buyerName: "Покупатель", buyerUid: null, anonymisedAt: now,
    }));
  }

  // A farm's own livestock and the lots nobody booked are its to take away.
  if (role === "partner") {
    await commitInBatches([...lots.docs, ...animals.docs], (batch, doc) => batch.delete(doc.ref));
  }

  const notifications = await db.collection("notifications").where("uid", "==", uid).get();
  await commitInBatches(notifications.docs, (batch, doc) => batch.delete(doc.ref));

  await deleteSubcollections(ownerRef);
  await ownerRef.delete().catch(() => {});

  // The account itself, last: a failure anywhere above leaves the person able to sign in and try
  // again, instead of locked out of data that is still there.
  await getAuth().deleteUser(uid).catch(() => {});

  return { deleted: true };
});
