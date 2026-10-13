// Наполняет боевой каталог: витрина хозяйства, животные и лоты с полными данными.
//
// Запускается РУКАМИ и только осознанно. Пишет в боевую базу, поэтому:
//   - без --write ничего не меняет, только печатает, что собирается сделать;
//   - проверяет идентификатор проекта и отказывается работать не с тем;
//   - пропускает то, что уже есть, так что повторный запуск безвреден.
//
// Доступ берётся из ключа сервисного аккаунта — его скачивают в консоли Firebase
// (Настройки проекта → Сервисные аккаунты → Создать закрытый ключ). Путь к ключу передаётся
// прямо в команде, переменные окружения не нужны:
//
//   node tools/seed-production-lots.cjs --key C:\путь\к\ключу.json            — показать план
//   node tools/seed-production-lots.cjs --key C:\путь\к\ключу.json --write    — применить
//
// Ключ — пароль от всей базы. Держите его вне репозитория и удалите, когда закончите.
const fs = require("fs");
const path = require("path");
const fnModules = path.join(__dirname, "../functions/node_modules");
const { initializeApp, cert, applicationDefault } = require(path.join(fnModules, "firebase-admin/lib/app/index.js"));
const { getFirestore, Timestamp } = require(path.join(fnModules, "firebase-admin/lib/firestore/index.js"));

const PROJECT = "farm-marketplace-demo";
const FARM = "demoFarmUid0000000000000001"; // Хаб «Степной»
const REGION = "KARAGANDY";
const WRITE = process.argv.includes("--write");

// Путь к ключу: из --key либо из переменной окружения, если она уже настроена.
const keyArg = process.argv.indexOf("--key");
const keyPath = (keyArg > -1 && process.argv[keyArg + 1]) || process.env.GOOGLE_APPLICATION_CREDENTIALS;

// Вход учётной записью вместо файла ключа. В проекте включена политика, запрещающая создавать
// ключи сервисных аккаунтов, — и это хорошая настройка: файл ключа живёт вечно и утекает
// вместе с папкой «Загрузки». `gcloud auth application-default login` выдаёт то же право, но
// привязанное к живому человеку и отзываемое.
const adcPath = path.join(process.env.APPDATA || process.env.HOME || "", "gcloud", "application_default_credentials.json");
const hasAdc = !keyPath && fs.existsSync(adcPath);

/**
 * Ищет уже скачанный ключ в обычных местах и предлагает готовую команду.
 *
 * Имя файла консоль Firebase выдаёт длинное и случайное, переписать его руками — отдельное
 * мучение, а ошибиться в одном знаке легко. Сами файлы не используем: только показываем, что
 * нашли. Выбор остаётся за человеком.
 */
function findKeys() {
  const home = process.env.USERPROFILE || process.env.HOME || "";
  const dirs = [path.join(home, "Downloads"), path.join(home, "Загрузки"), home];
  const found = [];
  for (const dir of dirs) {
    let names = [];
    try {
      names = fs.readdirSync(dir).filter((f) => f.endsWith(".json"));
    } catch { continue; }
    for (const name of names) {
      const full = path.join(dir, name);
      try {
        const j = JSON.parse(fs.readFileSync(full, "utf8"));
        if (j.type === "service_account" && j.project_id === PROJECT) found.push(full);
      } catch { /* не ключ — и ладно */ }
    }
  }
  return found;
}

if (!keyPath && !hasAdc) {
  const found = findKeys();
  console.error(`Нужен доступ к базе. Есть два способа.

СПОСОБ 1 — вход учётной записью, без файлов (предпочтительный).
Поставьте Google Cloud CLI — https://cloud.google.com/sdk/docs/install — и выполните:

  gcloud auth application-default login
  gcloud auth application-default set-quota-project ${PROJECT}

После этого запускайте скрипт вообще без аргументов. Ничего скачивать и хранить не надо,
доступ отзывается командой gcloud auth application-default revoke.

СПОСОБ 2 — файл ключа сервисного аккаунта.
  https://console.firebase.google.com/project/${PROJECT}/settings/serviceaccounts/adminsdk
Если там написано «Key creation is not allowed» — в проекте запрещено создавать такие ключи,
и это правильная настройка. Тогда остаётся способ 1.
`);
  if (found.length) {
    console.error(`Похоже, ключ уже скачан. Запустите:\n`);
    for (const f of found) console.error(`  node tools/seed-production-lots.cjs --key "${f}"\n`);
  } else {
    console.error(`Потом запустите, подставив настоящее имя скачанного файла:

  node tools/seed-production-lots.cjs --key "путь\\к\\файлу.json"
`);
  }
  console.error(`Сначала без --write: скрипт только покажет, что собирается сделать.
Ключ — пароль от всей базы. Удалите файл, когда закончите.`);
  process.exit(2);
}
if (hasAdc) {
  console.log("Вход: учётная запись gcloud\n");
  initializeApp({ credential: applicationDefault(), projectId: PROJECT });
} else {
  if (!fs.existsSync(keyPath)) {
    console.error(`Файл ключа не найден: ${keyPath}`);
    process.exit(2);
  }
  let key;
  try {
    key = JSON.parse(fs.readFileSync(keyPath, "utf8"));
  } catch {
    console.error(`${keyPath} — это не похоже на JSON-ключ сервисного аккаунта.`);
    process.exit(2);
  }
  // Ключ не от того проекта — самая дорогая из возможных ошибок: запись ушла бы в чужую базу.
  if (key.project_id !== PROJECT) {
    console.error(`Ключ от проекта «${key.project_id}», а нужен «${PROJECT}». Остановился.`);
    process.exit(2);
  }
  console.log(`Вход: ключ ${path.basename(keyPath)}\n`);
  initializeApp({ credential: cert(key), projectId: PROJECT });
}
const db = getFirestore();

// Витрина. Без неё у покупателя в заказе написано «доставка по договорённости» и нет цены —
// ровно то, на что указал комплаенс.
const STOREFRONT = {
  description:
    "Пастбищный откорм в Карагандинской области, 18–22 месяца. Свой убойный цех и камера "
    + "охлаждения: туша выдерживается 48 часов перед выдачей. Ветеринарное сопровождение на "
    + "каждом животном.",
  pickup: true,
  cutting: [
    { id: "cut_portion", name: "Порционная, в вакууме", price: 30000, note: "куски по 1–1,5 кг, подписаны" },
    { id: "cut_bone", name: "На кости, крупными кусками", price: 15000, note: "классические 12 жілік" },
  ],
  delivery: [
    { id: "dlv_krg", city: "Караганда", price: 8000 },
    { id: "dlv_ast", city: "Астана", price: 15000 },
  ],
};

// Животные заводятся раньше лотов: лот собирается из них, и к ним привязываются ветсправки.
const ANIMALS = [
  { key: "a_kazbel", type: "cattle", breed: "Казахская белоголовая", ageCategory: "торпақ", sex: "male", weight: 420, pricePerKg: 1900 },
  { key: "a_hereford", type: "cattle", breed: "Герефорд", ageCategory: "тайынша", sex: "male", weight: 470, pricePerKg: 2050 },
  { key: "a_akhal", type: "horse", breed: "Ахалтекинская", ageCategory: "тай", sex: "male", weight: 380, pricePerKg: 2400 },
  { key: "a_auliekol", type: "cattle", breed: "Аулиекольская", ageCategory: "тайынша", sex: "male", weight: 450, pricePerKg: 1980 },
  { key: "a_mugalzhar", type: "horse", breed: "Мугалжарская", ageCategory: "құнан", sex: "male", weight: 395, pricePerKg: 2350 },
];

// Лоты. totalShares = 2 — продаём половинами: так покупателей больше, и это единственный режим,
// который умеет нынешняя модель (половина или целая, четвертями не торгуем).
const LOTS = [
  {
    key: "a_kazbel",
    name: "Казахская белоголовая, торпақ",
    description:
      "Пастбищный откорм, 20 месяцев. Забой на собственном цехе, выдержка 48 часов в камере "
      + "охлаждения. Подходит для согыма и для домашней заморозки: мясо плотное, с ровным жиром.",
    meatType: "cattle",
    totalWeight: 215,
    pricePerKg: 3500,
    location: "Қарағанды облысы",
  },
  {
    key: "a_hereford",
    name: "Герефорд, тайынша",
    description:
      "Зерновой откорм 120 дней, мраморность выражена. Мякоть идёт на стейки и запекание, "
      + "передняя часть — на фарш и тушение. Разделка по вашему выбору при оформлении заказа.",
    meatType: "cattle",
    totalWeight: 240,
    pricePerKg: 3800,
    location: "Қарағанды облысы",
  },
  {
    key: "a_auliekol",
    name: "Аулиекольская, тайынша",
    description:
      "Пастбищный откорм, последние 90 дней с зерновой подкормкой. Порода выведена в Казахстане "
      + "и держит вес на сухой степи: мясо ровное по всей туше, без лишнего жира. Забой и "
      + "выдержка 48 часов — на цехе хозяйства.",
    meatType: "cattle",
    totalWeight: 230,
    pricePerKg: 3600,
    location: "Қарағанды облысы",
  },
  {
    key: "a_mugalzhar",
    name: "Мугалжарская, құнан",
    description:
      "Табунный выпас, нагул на полыни и типчаке. Казахская порода: жир плотный и белый, идёт "
      + "на казы и жал, мякоть — на сур-ет. Забой по правилам, с ветеринарным заключением на "
      + "животное.",
    meatType: "horse",
    totalWeight: 190,
    pricePerKg: 4400,
    location: "Қарағанды облысы",
  },
  {
    key: "a_akhal",
    name: "Ахалтекинская, тай",
    description:
      "Табунный выпас, два года. Конина на казы, шұжық и сур-ет: жир ровный, мясо без запаха. "
      + "Забой по правилам, с ветеринарным заключением на животное.",
    meatType: "horse",
    totalWeight: 180,
    pricePerKg: 4600,
    location: "Қарағанды облысы",
  },
];

const money = (n) => new Intl.NumberFormat("ru-RU").format(n) + " ₸";

(async () => {
  const farmRef = db.collection("partners").doc(FARM);
  const farmSnap = await farmRef.get();
  if (!farmSnap.exists) {
    console.error(`Хозяйство ${FARM} не найдено — проверьте идентификатор.`);
    process.exit(2);
  }
  const farm = farmSnap.data();
  console.log(`Хозяйство: ${farm.displayName} (${farm.phone}), статус ${farm.status}`);
  console.log(WRITE ? "РЕЖИМ ЗАПИСИ\n" : "Пробный прогон, ничего не меняется. Добавьте --write.\n");

  // 1. Витрина
  const hasStorefront = farm.storefront && (farm.storefront.description || (farm.storefront.delivery || []).length);
  console.log(`Витрина: ${hasStorefront ? "уже заполнена — пропускаю" : "будет заполнена"}`);
  if (!hasStorefront && WRITE) {
    await farmRef.set({ storefront: STOREFRONT, updatedAt: Timestamp.now() }, { merge: true });
  }

  // 2. Животные
  const ids = {};
  for (const a of ANIMALS) {
    const existing = await db.collection("animals")
      .where("partnerId", "==", FARM).where("breed", "==", a.breed).limit(1).get();
    if (!existing.empty) {
      ids[a.key] = existing.docs[0].id;
      console.log(`Животное «${a.breed}»: уже есть`);
      continue;
    }
    const ref = db.collection("animals").doc();
    ids[a.key] = ref.id;
    console.log(`Животное «${a.breed}»: будет заведено`);
    if (WRITE) {
      await ref.set({
        partnerId: FARM, type: a.type, breed: a.breed, ageCategory: a.ageCategory,
        sex: a.sex, weight: a.weight, pricePerKg: a.pricePerKg,
        createdAt: Timestamp.now(), updatedAt: Timestamp.now(),
      });
    }
  }

  // 3. Лоты
  for (const l of LOTS) {
    const existing = await db.collection("lots")
      .where("partnerId", "==", FARM).where("name", "==", l.name).limit(1).get();
    if (!existing.empty) {
      console.log(`Лот «${l.name}»: уже есть — пропускаю`);
      continue;
    }
    const whole = Math.round(l.pricePerKg * l.totalWeight);
    console.log(
      `Лот «${l.name}»: ${l.totalWeight} кг × ${money(l.pricePerKg)}/кг` +
      ` → целая ${money(whole)}, половина ${money(Math.round(whole / 2))}`,
    );
    if (!WRITE) continue;
    await db.collection("lots").doc().set({
      partnerId: FARM,
      name: l.name,
      description: l.description,
      meatType: l.meatType,
      totalShares: 2,
      bookedShares: 0,
      totalWeight: l.totalWeight,
      pricePerKg: l.pricePerKg,
      // Цена доли считается сервером при заказе; здесь она нужна старым экранам.
      pricePerShare: Math.round(whole / 2),
      location: l.location,
      regionCode: REGION,
      animalIds: ids[l.key] ? [ids[l.key]] : [],
      // Сразу в продажу: черновик покупатели не увидят, а смысл запуска — чтобы увидели.
      status: "open",
      createdAt: Timestamp.now(),
      updatedAt: Timestamp.now(),
    });
  }

  console.log(WRITE ? "\nГотово." : "\nЭто был пробный прогон. Для записи: --write");
})().catch((e) => { console.error("Сорвалось:", e.message); process.exit(1); });
