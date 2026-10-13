// Запускает платёжные тесты: поднимает эмуляторы с нужным окружением и прогоняет payments.test.cjs.
//
// Отдельный запускатор, а не строчка в npm scripts, по двум причинам. Первая — окружение надо
// отдать И эмулятору (функции читают оттуда ключ и адрес заглушки), И самому тесту, а inline-set
// в npm-скриптах на Windows и на Unix пишется по-разному. Вторая — ключ здесь заведомо ненастоящий:
// тесту всё равно, каким ключом подписано, лишь бы обе стороны знали один и тот же. Настоящий
// секрет в тестах не нужен и потому в них не попадает.
const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");

const root = path.join(__dirname, "../..");

// Эмулятор ищет секрет в Google Secret Manager и только потом смотрит в .secret.local. Без этого
// файла он ходит в интернет на каждом прогоне, а на машине с живым доступом ещё и притащит
// НАСТОЯЩИЙ ключ — то есть тест начнёт подписывать продакшен-ключом. Кладём заведомо тестовый.
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
// Все секреты, объявленные в коде, а не только платёжный. Пропустишь один — эмулятор пойдёт
// за ним в Secret Manager, и на машине без свежих кредов разбор функций встанет по таймауту:
// не зарегистрируется НИ ОДНА функция, а тест упадёт с «Function e... is not valid JSON», где
// про секреты нет ни слова. Диагностируется долго, чинится одной строкой.
const TEST_SECRETS = [
  `FREEDOMPAY_SECRET_PAY=${TEST_SECRET}`,
  "REKASSA_API_KEY=test_rekassa_key",
];
fs.writeFileSync(SECRET_FILE, TEST_SECRETS.join("\n") + "\n");

const env = {
  ...process.env,
  // Оплата включается только в эмуляторе и только этим флагом.
  ET_PAYMENTS: "on",
  // Ключ теста, а не кабинета. Одинаковый у функций и у теста — этого достаточно.
  FREEDOMPAY_SECRET_PAY: "test_secret_key",
  FREEDOMPAY_MERCHANT_ID: "000000",
  // Заглушка вместо их боевого init_payment.
  FREEDOMPAY_BASE: "http://127.0.0.1:8899",
  FREEDOMPAY_STUB_PORT: "8899",
  FREEDOMPAY_CALLBACK_BASE: "http://127.0.0.1:5001/demo-et/europe-west3",
  // Куда Freedom вернёт человека после оплаты. На стенде это местный сайт, иначе редирект
  // уводит на боевой example.kz, где этого заказа нет.
  ET_SITE_URL: process.env.ET_SITE_URL || "http://127.0.0.1:8795",
};

// Одной строкой через оболочку: аргумент emulators:exec — сам по себе команда, и в кавычках он
// должен остаться одним аргументом. Массив + shell:true на Windows разбирает его обратно по
// пробелам, и firebase жалуется на лишние аргументы.
const command = "firebase emulators:exec --only auth,firestore,functions --project demo-et"
  + ' "node tests/functions/payments.test.cjs"';
const child = spawn(command, { cwd: root, env, stdio: "inherit", shell: true });

child.on("exit", (code) => process.exit(code ?? 1));
