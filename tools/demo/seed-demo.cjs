// Наполняет ЭМУЛЯТОР данными для прогона руками: проверенное хозяйство с витриной, скот с
// бумагами, открытые лоты и готовый покупатель. Работает только против локальных эмуляторов и
// против проекта demo-et — на боевой базе отказывается запускаться.
//
//   node tools/demo/seed-demo.cjs
process.env.FIRESTORE_EMULATOR_HOST ||= "127.0.0.1:8085";
process.env.FIREBASE_AUTH_EMULATOR_HOST ||= "127.0.0.1:9099";
const PROJECT = process.env.ET_PROJECT || "demo-et";
process.env.GCLOUD_PROJECT = PROJECT;

const path = require("path");
const fnModules = path.join(__dirname, "../../functions/node_modules");
const { initializeApp } = require(path.join(fnModules, "firebase-admin/lib/app/index.js"));
const { getFirestore, Timestamp } = require(path.join(fnModules, "firebase-admin/lib/firestore/index.js"));
const { getAuth } = require(path.join(fnModules, "firebase-admin/lib/auth/index.js"));

if (!process.env.FIRESTORE_EMULATOR_HOST.startsWith("127.0.0.1")) {
  console.error("отказываюсь: FIRESTORE_EMULATOR_HOST не локальный");
  process.exit(2);
}

initializeApp({ projectId: PROJECT });
const db = getFirestore();
const auth = getAuth();

// Номера казахстанские не для красоты: экран входа в обоих приложениях ставит +7 сам, и номер
// другой страны там просто не набрать. Auth-эмулятор впускает по ним без настоящей SMS, код
// приходит не на телефон —
// его показывает сам эмулятор: http://127.0.0.1:9099/emulator/v1/projects/demo-et/verificationCodes
const FARM_PHONE = "+77010000001";
const BUYER_PHONE = "+77010000002";
const STAFF_PHONE = "+77010000003";

const FARM = "demo_farm";
const BUYER = "demo_buyer";
const STAFF = "demo_staff";

const lots = [
  {
    id: "DEMO_LOT_1", name: "Казахская белоголовая, торпақ",
    description: "Пасётся на разнотравье под Аршалы. Забой по заявке, мясо охлаждённое.",
    weight: 130, perKg: 3500, meatType: "cattle", shares: 2,
  },
  {
    id: "DEMO_LOT_2", name: "Ахалтекинская, жабағы",
    description: "Табунное содержание. Конина на казы и сұр ет.",
    weight: 170, perKg: 4200, meatType: "horse", shares: 2,
  },
  {
    id: "DEMO_LOT_3", name: "Герефорд, бычок",
    description: "Зерновой откорм последние три месяца. Мраморность заметная.",
    weight: 240, perKg: 3900, meatType: "cattle", shares: 2,
  },
];

(async () => {
  for (const [uid, phone] of [[FARM, FARM_PHONE], [BUYER, BUYER_PHONE], [STAFF, STAFF_PHONE]]) {
    await auth.createUser({ uid, phoneNumber: phone }).catch(() => {});
  }
  await auth.setCustomUserClaims(STAFF, { role: "admin" });

  const b = db.batch();

  b.set(db.doc(`partners/${FARM}`), {
    uid: FARM, phone: FARM_PHONE, role: "partner", displayName: "КХ «Степной»",
    iin: null, iban: null, country: null, documentUrl: null,
    // Проверку платформы хозяйство уже прошло — иначе у него нельзя заказать.
    status: "verified", reviewedAt: Timestamp.now(), reviewedBy: STAFF,
    createdAt: Timestamp.now(), avatarUrl: null, city: "Аршалы", regionCode: "KZ-11",
    rating: 0, totalDeals: 0, walletBalance: 0, pendingBalance: 0, achievements: [],
    storefront: {
      description: "Своё пастбище, свой убойный цех. Возим в Астану и Караганду.",
      cutting: [
        { id: "c1", name: "Порционная разделка", price: 8000, note: "в вакууме, по 1–1,5 кг" },
        { id: "c2", name: "Разделка на кости", price: 5000, note: "крупными кусками" },
      ],
      delivery: [
        { id: "d1", city: "Астана", price: 5000 },
        { id: "d2", city: "Караганда", price: 9000 },
      ],
      pickup: true,
    },
  });
  b.set(db.doc(`partners/${FARM}/private/identity`), { iin: "880101300123", updatedAt: Timestamp.now() });

  b.set(db.doc(`clients/${BUYER}`), {
    uid: BUYER, phone: BUYER_PHONE, role: "client", displayName: "Асхат",
    iin: null, iban: null, country: null, documentUrl: null, status: "active",
    createdAt: Timestamp.now(), avatarUrl: null, city: "Астана", rating: 0,
    totalDeals: 0, walletBalance: 0, pendingBalance: 0, achievements: [], email: null,
  });

  b.set(db.doc(`staff/${STAFF}`), { uid: STAFF, role: "admin", createdAt: Timestamp.now() });

  lots.forEach((lot, i) => {
    const animalId = `DEMO_ANIMAL_${i + 1}`;
    b.set(db.doc(`animals/${animalId}`), {
      partnerId: FARM, breed: lot.name.split(",")[0], subBreed: "", status: "active",
      weight: Math.round(lot.weight * 1.9),
      // Возраст приложение хранит словом, как его называет хозяйство: «торпақ» — бычок до
      // года, «тай» — годовалый жеребёнок. Английское young попадало на экран как есть.
      ageCategory: lot.meatType === "horse" ? "тай" : "торпақ",
      gender: "male", type: lot.meatType, imageUrl: null, notes: null, vetDocuments: [],
      // Цена ЗА КИЛОГРАММ живого веса — именно её просят и приложение, и сайт. Раньше сюда
      // клалась стоимость всей туши, и карточка животного показывала «455 000 ₸/кг».
      // Живой вес дороже убойного примерно вдвое по выходу, отсюда и коэффициент.
      price: Math.round(lot.perKg * 0.55), region: "Акмолинская область",
      regionCode: "KZ-11", createdAt: Timestamp.now(),
    });
    b.set(db.doc(`animals/${animalId}/documents/vet`), {
      partnerId: FARM, animalId, status: "approved", label: "Ветеринарная справка",
      fileUrl: "https://example.invalid/vet.pdf", fileName: "vet.pdf",
      contentType: "application/pdf", size: 120000, uploadedAt: Timestamp.now(),
      reviewedAt: Timestamp.now(), reviewedBy: STAFF, reviewNote: null,
    });
    b.set(db.doc(`lots/${lot.id}`), {
      partnerId: FARM, name: lot.name, description: lot.description,
      animalIds: [animalId], totalWeight: lot.weight, pricePerKg: lot.perKg,
      pricePerShare: Math.round((lot.weight * lot.perKg) / lot.shares),
      status: "open", totalShares: lot.shares, bookedShares: 0, imageUrl: null,
      location: "Акмолинская область", regionCode: "KZ-11", meatType: lot.meatType,
      vetDocuments: [], createdAt: Timestamp.now(),
    });
  });

  await b.commit();

  console.log("Эмулятор наполнен.\n");
  console.log("  Хозяйство   " + FARM_PHONE + "   КХ «Степной», проверено");
  console.log("  Покупатель  " + BUYER_PHONE + "   Асхат, Астана");
  console.log("  Сотрудник   " + STAFF_PHONE + "   админ (модерация отзывов и документов)");
  console.log("\n  Лоты: " + lots.map((l) => l.id).join(", "));
  console.log("\nКод из SMS не приходит — его показывает эмулятор:");
  console.log("  http://127.0.0.1:9099/emulator/v1/projects/" + PROJECT + "/verificationCodes");
  process.exit(0);
})();
