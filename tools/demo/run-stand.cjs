// Поднимает стенд для прогона руками: эмуляторы, песочница вместо Freedom Pay, демо-данные.
// Остаётся работать, пока не нажмёшь Ctrl+C.
//
//   node tools/demo/run-stand.cjs
//
// После запуска открывать сайт с ?emulator — он запомнит это на всю вкладку:
//   http://127.0.0.1:8795/?emulator
//
// С флагом --android стенд поднимается под боевым project id: приложения берут его из
// google-services.json и сменить не могут. Для этого нужен действующий вход в Firebase CLI
// (firebase login), потому что проект не "demo-". Сайт в этом режиме открывать как
//   http://127.0.0.1:8795/?emulator=app
// — иначе он пойдёт в demo-et и увидит другую базу, чем приложение.
const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");

const root = path.join(__dirname, "../..");

const SECRET_FILE = path.join(root, "functions", ".secret.local");
const TEST_SECRET = "test_secret_key";
if (fs.existsSync(SECRET_FILE)) {
  const current = fs.readFileSync(SECRET_FILE, "utf8");
  if (current.includes("FREEDOMPAY_SECRET_PAY") && !current.includes(TEST_SECRET)) {
    console.error(`В ${SECRET_FILE} лежит не тестовый ключ. Убери файл в сторону.`);
    process.exit(2);
  }
}
fs.writeFileSync(SECRET_FILE, `FREEDOMPAY_SECRET_PAY=${TEST_SECRET}\n`);

// `--android` — прогон не на сайте, а в приложении на Android-эмуляторе. Там 127.0.0.1 означает
// сам телефон, а машину, на которой всё это крутится, он знает как 10.0.2.2. Сами приложения
// про это знают (firebase_setup.dart), а вот страницу оплаты им надо отдать уже по этому адресу.
const android = process.argv.includes("--android");
const host = android ? "10.0.2.2" : "127.0.0.1";
// И project id. Приложения берут его из google-services.json и сменить не могут, поэтому в
// режиме приложений эмуляторы поднимаются под боевым идентификатором — иначе приложение
// смотрит в пустую базу и ведёт себя так, будто человека и лотов не существует.
const project = android ? "farm-marketplace-demo" : "demo-et";

const env = {
  ...process.env,
  ET_PAY_HOST: host,
  ET_PROJECT: project,
  ET_PAYMENTS: "on",
  FREEDOMPAY_SECRET_PAY: TEST_SECRET,
  FREEDOMPAY_MERCHANT_ID: "000000",
  FREEDOMPAY_BASE: "http://127.0.0.1:8899",
  FREEDOMPAY_STUB_PORT: "8899",
  FREEDOMPAY_CALLBACK_BASE: `http://127.0.0.1:5001/${project}/europe-west3`,
  // Куда Freedom вернёт человека после оплаты. На стенде это местный сайт, иначе редирект
  // уводит на боевой example.kz, где этого заказа нет.
  ET_SITE_URL: process.env.ET_SITE_URL || `http://${host}:8795`,
};

const sandbox = spawn(process.execPath, [path.join(__dirname, "freedom-sandbox.cjs")],
  { cwd: root, env, stdio: "inherit" });

// emulators:exec держит эмуляторы ровно столько, сколько живёт его команда. Команда здесь —
// наполнить базу и ждать: так стенд не разваливается, когда наполнение закончилось.
const inner = "node tools/demo/seed-demo.cjs && node tools/demo/keep-alive.cjs";
const emulators = spawn(
  `firebase emulators:exec --only auth,firestore,functions,storage --project ${project} "${inner}"`,
  { cwd: root, env, stdio: "inherit", shell: true },
);

const stop = () => {
  sandbox.kill();
  emulators.kill();
  process.exit(0);
};
process.on("SIGINT", stop);
process.on("SIGTERM", stop);
emulators.on("exit", (code) => { sandbox.kill(); process.exit(code ?? 0); });
