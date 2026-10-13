// Seeds the LOCAL emulators for exercising the staff panel. Refuses to run against anything else.
//
//   firebase emulators:start --only auth,firestore,functions,storage --project demo-et
//   node functions/seed-emulator.cjs
//
// Includes hostile strings on purpose - a farm name and a file name carrying HTML - because the
// staff panel is exactly where an unescaped string would turn into a hijacked admin session.
process.env.FIRESTORE_EMULATOR_HOST ||= "127.0.0.1:8085";
process.env.FIREBASE_AUTH_EMULATOR_HOST ||= "127.0.0.1:9099";
// The apps cannot change their project id at runtime (Android boots Firebase from
// google-services.json), so seeding for an app test runs against that same id:
//   ET_PROJECT=farm-marketplace-demo node functions/seed-emulator.cjs
const PROJECT = process.env.ET_PROJECT || "demo-et";
process.env.GCLOUD_PROJECT = PROJECT;

const { initializeApp } = require("firebase-admin/app");
const { getFirestore, Timestamp } = require("firebase-admin/firestore");
const { getAuth } = require("firebase-admin/auth");

if (!process.env.FIRESTORE_EMULATOR_HOST.startsWith("127.0.0.1")) {
  console.error("refusing: FIRESTORE_EMULATOR_HOST is not local");
  process.exit(1);
}

initializeApp({ projectId: PROJECT });
const db = getFirestore();
const auth = getAuth();
const daysAgo = (n) => Timestamp.fromMillis(Date.now() - n * 86400000);

(async () => {
  // Someone the admin can later grant a role to - roles attach to existing accounts only.
  await auth.createUser({ uid: "support-person", phoneNumber: "+15550003333" }).catch(() => {});
  // A buyer who can sign in on the site, to see their order tracker and dispute from their side.
  await auth.createUser({ uid: "buyer2", phoneNumber: "+15550007777" }).catch(() => {});
  // The checked farm, to sign in to its cabinet (Витрина, orders).
  await auth.createUser({ uid: "farm_ok", phoneNumber: "+15550005555" }).catch(() => {});

  const b = db.batch();
  // Registered the way the site does it now: IIN and exact point in private records, a region
  // code, and the ~5 km public point setHubLocation would have derived.
  b.set(db.doc("partners/farm_pending"), {
    uid: "farm_pending", displayName: "КХ Ждущее", phone: "+15550002222", iin: null,
    city: "с. Ботакара", regionCode: "KZ-35", status: "pending_review", createdAt: daysAgo(3), rating: 0, walletBalance: 0,
    publicLocation: { lat: 50.0135, lng: 73.7051, precisionKm: 5 },
  });
  b.set(db.doc("partners/farm_pending/private/identity"), { iin: "123456789012", updatedAt: daysAgo(3) });
  b.set(db.doc("partners/farm_pending/private/location"), { lat: 50.02147, lng: 73.71512, updatedAt: daysAgo(3) });
  b.set(db.doc("partners/farm_xss"), {
    uid: "farm_xss", displayName: "<img src=x onerror=\"window.__xss=1\">КХ Взлом", phone: "+15550004444",
    iin: "<b>000</b>", city: "<script>window.__xss=2</script>", status: "pending_review", createdAt: daysAgo(1),
  });
  // An app-registered farm keeps its IIN on the public profile (what ET Partners still does);
  // farm_xss above is one too. farm_ok is checked, with a public point for the homepage map.
  b.set(db.doc("partners/farm_ok"), {
    uid: "farm_ok", displayName: "Хаб Тестовый", phone: "+15550005555", status: "verified", createdAt: daysAgo(30),
    city: "Астана", regionCode: "KZ-71", publicLocation: { lat: 51.1364, lng: 71.4747, precisionKm: 5 },
    // The rating is not a number someone typed: it is the average of the published reviews below,
    // exactly as moderateReview recomputes it.
    certified: true, rating: 4.5, reviewsCount: 2,
    storefront: {
      description: "Откорм на пастбищах Акмолинской области, 18–24 месяца.\nСвой убойный цех и камера охлаждения.",
      cutting: [{ id: "c1", name: "Традиционная Мүшелеу", price: 15000, note: "12 жілік, казы, бас-сирақ" }],
      delivery: [{ id: "d1", city: "Астана", price: 5000 }, { id: "d2", city: "Караганда", price: 15000 }],
      pickup: true,
    },
  });
  b.set(db.doc("partners/farm_ok/private/legal"), { form: "kh", legalName: "КХ «Тестовый»", address: "Астана, ул. Тестовая 1", updatedAt: daysAgo(30) });
  b.set(db.doc("partners/farm_pending/private/legal"), { form: "ip", legalName: "ИП Ждущий", address: "с. Ботакара, ул. Степная 3", updatedAt: daysAgo(3) });
  b.set(db.doc("partners/farm_pending/documents/cert_ses"), {
    kind: "ses", label: "Санитарно-эпидемиологическое заключение (СЭС)", fileName: "ses.pdf", contentType: "application/pdf",
    size: 80000, fileUrl: "https://example.invalid/ses.pdf", status: "pending", partnerId: "farm_pending",
    uploadedAt: daysAgo(1.5), reviewedAt: null, reviewedBy: null, reviewNote: null,
  });
  b.set(db.doc("partners/farm_ok/private/review"), { decision: "approve", note: null, decidedAt: daysAgo(29), decidedBy: "seed" });
  b.set(db.doc("animals/a1"), { partnerId: "farm_pending", breed: "Ангус", weight: 420, createdAt: daysAgo(9) });
  b.set(db.doc("animals/a2"), { partnerId: "farm_ok", breed: "Казахская белоголовая", weight: 480, type: "cattle", ageCategory: "торпақ", gender: "male", price: 3500, region: "Акмолинская область", regionCode: "KZ-11", createdAt: daysAgo(8) });
  // A second checked farm, horse meat, in another zone - so the catalogue's zone, meat, breed, age
  // and budget filters have something to tell apart.
  b.set(db.doc("partners/farm_horse"), {
    uid: "farm_horse", displayName: "КХ Мугалжар", phone: "+15550008888", status: "verified", createdAt: daysAgo(20),
    city: "Актобе", regionCode: "KZ-15", rating: 4.6, publicLocation: { lat: 50.2839, lng: 57.167, precisionKm: 5 },
  });
  b.set(db.doc("animals/a3"), { partnerId: "farm_horse", breed: "Мугалжарская", weight: 360, type: "horse", ageCategory: "кунан", gender: "male", price: 3000, region: "Актюбинская область", regionCode: "KZ-15", createdAt: daysAgo(7) });
  b.set(db.doc("lots/lot3"), {
    partnerId: "farm_horse", name: "Конина, құнан — туша", status: "open", bookedShares: 0, totalShares: 2,
    pricePerKg: 3000, pricePerShare: 180000, totalWeight: 120, animalIds: ["a3"], meatType: "horse", regionCode: "KZ-15",
    location: "Актюбинская область", createdAt: daysAgo(1),
  });
  // A carcass in the current shape at the certified farm: two halves, a price per kilogram, one
  // animal with paperwork - what the order configurator and checkout are built around.
  b.set(db.doc("animals/a4"), { partnerId: "farm_ok", breed: "Казахская белоголовая", weight: 420, price: 3500, type: "cattle", ageCategory: "торпақ", gender: "female", region: "Акмолинская область", regionCode: "KZ-11", createdAt: daysAgo(6) });
  b.set(db.doc("animals/a4/documents/d4"), {
    kind: "vet_certificate", label: "Ветеринарная справка (форма №1)", fileName: "a4.pdf", contentType: "application/pdf",
    size: 50000, fileUrl: "https://example.invalid/a4.pdf", status: "approved", partnerId: "farm_ok", animalId: "a4",
    uploadedAt: daysAgo(5), reviewedAt: daysAgo(4), reviewedBy: "seed", reviewNote: null,
  });
  b.set(db.doc("lots/lot4"), {
    partnerId: "farm_ok", name: "Казахская белоголовая, торпақ", status: "open", bookedShares: 0, totalShares: 2,
    pricePerKg: 3500, totalWeight: 130, pricePerShare: 227500, animalIds: ["a4"], meatType: "cattle",
    regionCode: "KZ-71", location: "Астана", createdAt: daysAgo(0.5),
  });
  b.set(db.doc("animals/a1/documents/d1"), {
    kind: "vet_certificate", label: "Ветеринарная справка (форма №1)",
    fileName: "справка<script>window.__xss=3</script>.pdf", contentType: "application/pdf", size: 120000,
    fileUrl: "https://example.invalid/d1.pdf", status: "pending", partnerId: "farm_pending", animalId: "a1",
    uploadedAt: daysAgo(2), reviewedAt: null, reviewedBy: null, reviewNote: null,
  });
  b.set(db.doc("animals/a2/documents/d2"), {
    kind: "lab_report", label: "Заключение лаборатории", fileName: "lab.jpg", contentType: "image/jpeg",
    size: 90000, fileUrl: "https://example.invalid/lab.jpg", status: "pending", partnerId: "farm_ok",
    animalId: "a2", uploadedAt: daysAgo(0.2), reviewedAt: null, reviewedBy: null, reviewNote: null,
  });
  b.set(db.doc("lots/lot1"), { partnerId: "farm_ok", name: "Белоголовая — партия 1", status: "fully_booked", bookedShares: 4, totalShares: 4 });
  b.set(db.doc("lots/lot2"), {
    partnerId: "farm_ok", name: "Ангус — полутуша", status: "open", bookedShares: 1, totalShares: 6,
    pricePerShare: 77000, totalWeight: 160, animalIds: ["a2"], meatType: "cattle", regionCode: "KZ-71", location: "Астана",
    createdAt: daysAgo(3),
  });
  b.set(db.doc("orders/o1"), {
    buyerUid: "buyer1", buyerPhone: "+15550006666", contactPhone: "+15550006666", partnerId: "farm_ok",
    lotId: "lot1", lotTitle: "Белоголовая — партия 1", shares: 4, pricePerShare: 90000, amount: 360000,
    status: "created", deliveryAddress: "Караганда, ул. Тестовая 1", createdAt: daysAgo(5),
    payment: { status: "not_required" }, statusHistory: [{ status: "created", at: daysAgo(5), by: "buyer1" }],
  });
  b.set(db.doc("orders/o2"), {
    buyerUid: "buyer2", buyerPhone: "+15550007777", contactPhone: "+15550007777", partnerId: "farm_ok",
    lotId: "lot2", lotTitle: "Ангус — полутуша", shares: 1, pricePerShare: 77000, amount: 77000,
    status: "delivered", deliveryAddress: "Астана, пр. Тестовый 5", createdAt: daysAgo(2),
    payment: { status: "not_required" },
    statusHistory: [
      { status: "created", at: daysAgo(2), by: "buyer2" },
      { status: "confirmed", at: daysAgo(1.8), by: "farm_ok" },
      { status: "in_progress", at: daysAgo(1), by: "farm_ok" },
      { status: "delivered", at: daysAgo(0.3), by: "farm_ok" },
    ],
  });
  b.set(db.doc("clients/buyer2"), {
    uid: "buyer2", phone: "+15550007777", role: "client", displayName: "Покупатель Тестовый", city: "Астана",
    status: "active", createdAt: daysAgo(10),
  });
  b.set(db.doc("clients/buyer2/purchases/lot2"), {
    lotId: "lot2", shares: 1, amountPaid: 77000, orderIds: ["o2"], purchaseDate: daysAgo(2), lotTitle: "Ангус — полутуша",
  });
  // lot2's production steps with the farmer's photos - what the buyer's tracker has to show.
  const steps = [
    ["step_1_selection", "Отбор", "Выбор животных"], ["step_2_preparation", "Подготовка", "Предпродажная подготовка"],
    ["step_3_processing", "Обработка", "Убойный цех"], ["step_4_packaging", "Упаковка", "Фасовка и маркировка"],
    ["step_5_dispatch", "Отправка", "Погрузка и транспорт"], ["step_6_delivery", "Доставка", "Передача клиенту"],
  ];
  steps.forEach(([id, title, subtitle], i) => b.set(db.doc(`lots/lot2/deliveries/${id}`), {
    id, lotId: "lot2", title, subtitle, description: subtitle, order: i + 1,
    status: i < 3 ? "completed" : i === 3 ? "current" : "pending",
    completedAt: i < 3 ? daysAgo(1.5 - i * 0.4) : null,
    mediaUrl: i < 3 ? "/assets/icon.png" : null,
  }));
  // Disputes: a fresh one carrying HTML (the staff panel and the buyer's page must print it as
  // text), and one already taken into work.
  b.set(db.doc("disputes/disp_new"), {
    uid: "buyer2", lotId: "lot2", status: "new", mediaUrl: null, createdAt: daysAgo(0.1),
    description: "Мясо с запахом <img src=x onerror=\"window.__xss=4\">, часть кусков не те.",
  });
  b.set(db.doc("disputes/disp_review"), {
    uid: "buyer1", lotId: "lot1", status: "in_review", mediaUrl: "https://example.invalid/evidence.jpg",
    description: "Недовес около 8 кг против заявленного.", createdAt: daysAgo(3), takenAt: daysAgo(2.5), handledBy: "seed",
  });
  // Reviews: two published (their average IS farm_ok's rating above) and one waiting for a
  // moderator, so the panel's queue and the farm's page both have something real to show. One
  // carries HTML again - a review is the one text a stranger writes onto a farm's public page.
  b.set(db.doc("reviews/o2"), {
    orderId: "o2", lotId: "lot2", lotTitle: "Ангус — полутуша", partnerId: "farm_ok",
    buyerUid: "buyer2", buyerName: "Покупатель Тестовый", rating: 5,
    text: "Мясо отличное, вес совпал, фермер снимал каждый шаг.",
    status: "published", createdAt: daysAgo(1), moderatedAt: daysAgo(0.9), moderatedBy: "seed", moderationNote: null,
  });
  b.set(db.doc("reviews/o_old"), {
    orderId: "o_old", lotId: "lot1", lotTitle: "Белоголовая — партия 1", partnerId: "farm_ok",
    buyerUid: "buyer1", buyerName: "Покупатель Первый", rating: 4,
    text: "Доставили на день позже, качеством доволен.",
    status: "published", createdAt: daysAgo(6), moderatedAt: daysAgo(5.8), moderatedBy: "seed", moderationNote: null,
  });
  b.set(db.doc("reviews/o_pending"), {
    orderId: "o_pending", lotId: "lot2", lotTitle: "Ангус — полутуша", partnerId: "farm_horse",
    buyerUid: "buyer2", buyerName: "<img src=x onerror=\"window.__xss=5\">Покупатель",
    rating: 2, text: "Пишу гадость <b>жирным</b> — модератор должен это увидеть как текст.",
    status: "pending", createdAt: daysAgo(0.2), moderatedAt: null, moderatedBy: null, moderationNote: null,
  });
  // A joint purchase still gathering: one place taken of three, nothing held on the lot.
  b.set(db.doc("groupBuys/group_open"), {
    lotId: "lot4", lotTitle: "Казахская белоголовая, торпақ", partnerId: "farm_ok", partnerName: "Хаб Тестовый",
    format: "half", shares: 1, size: 3, amount: 232500, perMember: [77500, 77500, 77500],
    pricing: { meat: 227500, cutting: 0, delivery: 5000, total: 232500 },
    estimatedWeightKg: 65, pricePerKg: 3500, cutting: null, cuttingId: null,
    delivery: { mode: "city", id: "d1", city: "Астана", amount: 5000 }, deliveryId: "d1",
    deliveryDate: null, deliverySlot: "any",
    creatorUid: "buyer2", creatorName: "Покупатель Тестовый",
    members: [{ uid: "buyer2", name: "Покупатель Тестовый", amount: 77500, joinedAt: daysAgo(0.3) }],
    memberUids: ["buyer2"], status: "open", orderId: null, createdAt: daysAgo(0.3), updatedAt: daysAgo(0.3),
  });
  b.set(db.doc("groupBuys/group_open/private/contact"), {
    deliveryAddress: "Астана, пр. Тестовый 5, кв. 12", contactPhone: "+15550007777", updatedAt: daysAgo(0.3),
  });
  await b.commit();
  console.log("seeded: 4 farms (2 checked - one certified with a storefront, one horse; 2 pending, 1 hostile), 3 animals, 3 pending documents (1 a farm certificate), 3 lots, 2 orders, 2 disputes, 3 reviews (1 waiting), 1 joint purchase gathering, a buyer and a farm who can sign in, 1 spare account");
})().catch((e) => { console.error(e); process.exit(1); });
