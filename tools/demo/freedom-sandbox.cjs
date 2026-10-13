// Песочница вместо Freedom Pay: отвечает на их четыре скрипта и показывает собственную страницу
// оплаты с двумя кнопками — «оплатить» и «отказаться».
//
// Нужна для прогона руками. Автоматические тесты обходятся заглушкой внутри себя, а человеку
// надо куда-то нажать: настоящая страница Freedom просит карту, а в эмуляторе карты нет и быть
// не должно. Подпись здесь считается по-настоящему, обеими сторонами, — если мы где-то её
// сломаем, песочница откажет ровно так же, как откажет их сервер.
//
//   node tools/demo/freedom-sandbox.cjs
const http = require("http");
const path = require("path");
const { pathToFileURL } = require("url");

const PORT = Number(process.env.FREEDOMPAY_STUB_PORT || 8899);
// Адрес, по которому страницу оплаты откроет ТОТ, кто платит. Для браузера на этой же машине это
// 127.0.0.1, а для приложения в Android-эмуляторе — 10.0.2.2: внутри эмулятора 127.0.0.1 означает
// сам телефон, и страница оплаты просто не откроется. Отсюда и отдельная настройка.
const PUBLIC_HOST = process.env.ET_PAY_HOST || "127.0.0.1";
const KEY = process.env.FREEDOMPAY_SECRET_PAY || "test_secret_key";
const CALLBACK = process.env.FREEDOMPAY_CALLBACK_BASE
  || "http://127.0.0.1:5001/demo-et/europe-west3";

(async () => {
  const fp = await import(pathToFileURL(path.join(__dirname, "../../functions/freedompay.js")).href);

  // Что мы приняли: номер заказа, сумма, куда вернуть человека. Живёт в памяти — песочница
  // одноразовая, и переживать перезапуск ей незачем.
  const payments = new Map();
  let nextId = 50001;

  const page = (title, body) => `<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>${title}</title>
<style>
  :root { color-scheme: light }
  body { margin:0; min-height:100vh; display:grid; place-items:center;
         font:16px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif; background:#F2EEE6; color:#1C1A17 }
  .card { width:min(420px,92vw); background:#fff; border:1px solid #E3DCCF; border-radius:18px;
          padding:28px; box-shadow:0 12px 36px rgba(28,26,23,.10) }
  .mark { font:700 12px/1 system-ui; letter-spacing:.14em; color:#9A5B3A; text-transform:uppercase }
  h1 { font-size:22px; margin:12px 0 4px }
  .sum { font-size:34px; font-weight:800; margin:14px 0 2px }
  .muted { color:#6B6256; font-size:14px }
  form { margin-top:22px; display:grid; gap:10px }
  button { font:600 15px/1 system-ui; padding:14px; border-radius:12px; border:0; cursor:pointer }
  .pay { background:#1F7A4D; color:#fff }
  .no { background:#fff; color:#8A3A2A; border:1px solid #E3DCCF }
  .note { margin-top:18px; padding:12px; background:#FBF3E4; border-radius:10px; font-size:13px; color:#6B6256 }
</style></head><body><div class="card">${body}</div></body></html>`;

  const server = http.createServer((req, res) => {
    const url = new URL(req.url, "http://127.0.0.1");

    // ---- страница оплаты, на которую мы сами же и отправили человека ----------------------------
    if (url.pathname === "/pay" && req.method === "GET") {
      const p = payments.get(url.searchParams.get("id"));
      if (!p) {
        res.writeHead(404, { "content-type": "text/html; charset=utf-8" });
        res.end(page("Нет такого платежа", "<h1>Платёж не найден</h1>"));
        return;
      }
      res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
      res.end(page("Оплата заказа", `
        <div class="mark">Песочница вместо Freedom Pay</div>
        <h1>${p.description}</h1>
        <div class="sum">${Number(p.amount).toLocaleString("ru-RU")} ₸</div>
        <div class="muted">Заказ ${p.orderId}</div>
        <form method="POST" action="/pay/decide">
          <input type="hidden" name="id" value="${p.id}">
          <button class="pay" name="result" value="1">Оплатить картой</button>
          <button class="no" name="result" value="0">Отказаться от оплаты</button>
        </form>
        <div class="note">Денег здесь нет. Это локальный стенд: нажатие отправляет такое же
        уведомление, какое прислал бы их сервер, с такой же подписью.</div>`));
      return;
    }

    // ---- человек нажал: шлём уведомление и возвращаем его на сайт --------------------------------
    if (url.pathname === "/pay/decide" && req.method === "POST") {
      let body = "";
      req.on("data", (c) => { body += c; });
      req.on("end", async () => {
        const form = new URLSearchParams(body);
        const p = payments.get(form.get("id"));
        if (!p) { res.writeHead(404).end(); return; }
        const ok = form.get("result") === "1";

        const fields = fp.signed("freedompayResult", {
          pg_order_id: p.orderId,
          pg_payment_id: p.id,
          pg_amount: p.amount,
          pg_currency: "KZT",
          pg_result: ok ? 1 : 0,
          pg_can_reject: ok ? "1" : "0",
          pg_payment_method: "test card",
          ...(ok ? {} : { pg_failure_code: "1001", pg_failure_description: "Отказ банка (стенд)" }),
        }, KEY);

        try {
          const answer = await fetch(`${CALLBACK}/freedompayResult`, {
            method: "POST",
            headers: { "content-type": "application/x-www-form-urlencoded" },
            body: new URLSearchParams(fields).toString(),
          });
          console.log(`[sandbox] ${ok ? "оплата" : "отказ"} ${p.orderId} → ${answer.status}`);
        } catch (e) {
          console.error("[sandbox] уведомление не ушло:", e.message);
        }
        res.writeHead(302, { location: ok ? p.successUrl : p.failureUrl }).end();
      });
      return;
    }

    // ---- их API ----------------------------------------------------------------------------------
    let body = "";
    req.on("data", (c) => { body += c; });
    req.on("end", () => {
      const script = fp.scriptNameOf(`http://x${req.url}`);
      const params = fp.parseCallbackBody(req.headers["content-type"], body);
      res.setHeader("content-type", "application/xml");

      if (!fp.verify(script, params, KEY)) {
        console.warn(`[sandbox] ${script}: подпись не сошлась`);
        res.end('<?xml version="1.0"?><response><pg_status>error</pg_status>'
          + "<pg_error_code>9998</pg_error_code>"
          + "<pg_error_description>Некорректная подпись запроса</pg_error_description></response>");
        return;
      }

      const reply = (fields) => res.end('<?xml version="1.0"?><response>'
        + Object.entries(fp.signed(script, fields, KEY))
          .map(([k, v]) => `<${k}>${String(v).replaceAll("&", "&amp;")}</${k}>`).join("")
        + "</response>");

      if (script === "init_payment.php") {
        const id = String(nextId++);
        payments.set(id, {
          id,
          orderId: String(params.pg_order_id),
          amount: String(params.pg_amount),
          description: String(params.pg_description || "Заказ"),
          successUrl: String(params.pg_success_url || "/"),
          failureUrl: String(params.pg_failure_url || "/"),
        });
        console.log(`[sandbox] платёж ${id} на ${params.pg_amount} ₸, заказ ${params.pg_order_id}`
          + `, холд: ${params.pg_auto_clearing === "0" ? "да" : "нет"}`);
        reply({
          pg_status: "ok",
          pg_payment_id: id,
          pg_redirect_url: `http://${PUBLIC_HOST}:${PORT}/pay?id=${id}`,
          pg_redirect_url_type: "payment system",
        });
        return;
      }

      const what = { "do_capture.php": "списание", "cancel.php": "снятие холда", "revoke.php": "возврат" };
      if (what[script]) {
        const sum = params.pg_clearing_amount || params.pg_refund_amount || "";
        console.log(`[sandbox] ${what[script]} по платежу ${params.pg_payment_id}`
          + (sum ? ` на ${sum} ₸` : ""));
        reply({ pg_status: "ok" });
        return;
      }

      reply({ pg_status: "error", pg_error_code: "9999", pg_error_description: "Неизвестный скрипт" });
    });
  });

  server.listen(PORT, "127.0.0.1", () => {
    console.log(`Песочница Freedom Pay на http://127.0.0.1:${PORT}`);
    if (PUBLIC_HOST !== "127.0.0.1") console.log(`Платёжную страницу отдаём как http://${PUBLIC_HOST}:${PORT}/pay`);
    console.log("Уведомления уходят на " + CALLBACK + "/freedompayResult");
  });
})();
