// Запускает сквозной тест полного круга: поднимает эмуляторы с тем же окружением, что и
// платёжные тесты, и прогоняет full-cycle.test.mjs.
//
// Окружение то же и по той же причине: ключ заведомо ненастоящий, оплата включается только
// флагом и только в эмуляторе, Freedom Pay подменён заглушкой внутри самого теста.
const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");

const root = path.join(__dirname, "../..");

const SECRET_FILE = path.join(root, "functions", ".secret.local");
const TEST_SECRET = "test_secret_key";
if (fs.existsSync(SECRET_FILE)) {
  const current = fs.readFileSync(SECRET_FILE, "utf8");
  if (current.includes("FREEDOMPAY_SECRET_PAY") && !current.includes(TEST_SECRET)) {
    console.error(`В ${SECRET_FILE} лежит не тестовый ключ.`);
    console.error("Тесты его не тронут — убери файл в сторону и запусти ещё раз.");
    process.exit(2);
  }
}
fs.writeFileSync(SECRET_FILE, `FREEDOMPAY_SECRET_PAY=${TEST_SECRET}\n`);

const env = {
  ...process.env,
  ET_PAYMENTS: "on",
  FREEDOMPAY_SECRET_PAY: TEST_SECRET,
  FREEDOMPAY_MERCHANT_ID: "000000",
  FREEDOMPAY_BASE: "http://127.0.0.1:8899",
  FREEDOMPAY_STUB_PORT: "8899",
  FREEDOMPAY_CALLBACK_BASE: "http://127.0.0.1:5001/demo-et/europe-west3",
  // Куда Freedom вернёт человека после оплаты. На стенде это местный сайт, иначе редирект
  // уводит на боевой example.kz, где этого заказа нет.
  ET_SITE_URL: process.env.ET_SITE_URL || "http://127.0.0.1:8795",
};

const command = "firebase emulators:exec --only auth,firestore,functions --project demo-et"
  + ' "node tests/functions/full-cycle.test.mjs"';
const child = spawn(command, { cwd: root, env, stdio: "inherit", shell: true });

child.on("exit", (code) => process.exit(code ?? 1));
