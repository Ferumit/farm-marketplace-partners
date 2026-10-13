/**
 * Подпись сообщений Freedom Pay.
 *
 * Это единственное место в платежах, где ошибка не видна глазом: неправильная подпись — это либо
 * молчаливо неработающая оплата, либо принятый чужой вебхук. Поэтому алгоритм здесь не выведен из
 * описания в документации, а перенесён один в один с эталонной реализации Platron
 * (PG_Signature.php), от которой Freedom Pay происходит, — со всеми её странностями.
 *
 * Странности, которые легко потерять при «чистом» переписывании и каждая из которых ломает подпись:
 *
 *   • Имя параметра в плоском виде — `ключ` + порядковый номер тремя цифрами: `pg_amount001`.
 *     Номер нужен, чтобы вложенные узлы не перепутались при сортировке.
 *   • Счётчик увеличивается и на пропущенном `pg_sig` тоже.
 *   • У числового ключа (элемент массива) имя родителя теряет последние три цифры и получает
 *     свой номер: `pg_receipt_positions001` → `pg_receipt_positions002` для второго элемента.
 *   • При совпадении имён побеждает ПЕРВОЕ значение (в PHP это `+=`, а не `array_merge`).
 *   • Сортировка — по плоскому имени, побайтово. Ключи у нас всегда начинаются с буквы, поэтому
 *     числовой сортировки PHP тут можно не бояться.
 *   • Значения ничем не экранируются, и разделитель `;` внутри значения сместит всю строку.
 *     Это свойство протокола, а не наше: см. тест «точка с запятой внутри значения».
 *
 * Имя скрипта — последний сегмент пути. Для наших ответов это имя НАШЕГО обработчика
 * (`freedompayResult`), а не их скрипта: обе стороны считают подпись по тому адресу, на который
 * сообщение пришло.
 */

import { createHash } from "node:crypto";

/** PHP-приведение к строке: null и false — пустая строка, true — «1». */
function toPhpString(value) {
  if (value === null || value === undefined || value === false) return "";
  if (value === true) return "1";
  return String(value);
}

/**
 * Плоский вид параметров — порт makeFlatParamsArray.
 *
 * @param {object|Array} params
 * @param {string} parentName
 * @param {Map<string,string>} into
 */
function flatten(params, parentName = "", into = new Map()) {
  const isArray = Array.isArray(params);
  const entries = isArray
    ? params.map((value, index) => [index, value])
    : Object.entries(params);

  let i = 0;
  for (const [key, value] of entries) {
    i += 1;
    // Счётчик уже увеличен: пропуск pg_sig не сдвигает нумерацию остальных.
    if (key === "pg_sig") continue;

    const counter = String(i).padStart(3, "0");
    const name = typeof key === "number"
      ? parentName.slice(0, Math.max(0, parentName.length - 3)) + counter
      : parentName + key + counter;

    if (value !== null && typeof value === "object") {
      flatten(value, name, into);
      continue;
    }
    // Первое значение побеждает — как `+=` в PHP.
    if (!into.has(name)) into.set(name, toPhpString(value));
  }
  return into;
}

/**
 * Строка, от которой берётся md5. Отдельно от [sign] только ради тестов и разбора инцидентов:
 * когда подпись не сходится, смотреть надо именно на неё.
 */
export function signatureString(scriptName, params, secret) {
  const flat = flatten(params);
  const names = [...flat.keys()].sort();
  return [scriptName, ...names.map((n) => flat.get(n)), secret].join(";");
}

/** Подпись запроса или ответа. 32 шестнадцатеричных символа в нижнем регистре. */
export function sign(scriptName, params, secret) {
  return createHash("md5").update(signatureString(scriptName, params, secret), "utf8").digest("hex");
}

/**
 * Проверка подписи пришедшего сообщения.
 *
 * Сравнение по длине и содержимому, без раннего выхода: подпись — это то, что отделяет
 * уведомление Freedom Pay от чьего угодно POST'а, и утечка через время сравнения здесь не нужна.
 */
export function verify(scriptName, params, secret) {
  const given = String(params?.pg_sig ?? "");
  if (given.length !== 32) return false;
  const expected = sign(scriptName, params, secret);
  let diff = 0;
  for (let i = 0; i < 32; i += 1) diff |= given.charCodeAt(i) ^ expected.charCodeAt(i);
  return diff === 0;
}

/** Случайная соль. Латиница и цифры — как просит документация. */
export function salt(length = 16) {
  const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
  let out = "";
  for (let i = 0; i < length; i += 1) {
    out += alphabet[Math.floor(Math.random() * alphabet.length)];
  }
  return out;
}

/** Параметры с солью и подписью — то, что уходит в запрос. */
export function signed(scriptName, params, secret) {
  const withSalt = { ...params, pg_salt: params.pg_salt ?? salt() };
  return { ...withSalt, pg_sig: sign(scriptName, withSalt, secret) };
}

/**
 * Ответ на их уведомление. Формат задан ими: XML с нашей подписью, иначе уведомление будет
 * приходить снова каждые полчаса в течение двух часов.
 *
 * @param {string} scriptName имя НАШЕГО обработчика — последний сегмент result_url
 * @param {"ok"|"rejected"|"error"} status
 */
export function replyXml(scriptName, status, description, secret) {
  const body = signed(scriptName, { pg_status: status, pg_description: description }, secret);
  const escape = (s) => String(s)
    .replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
  return '<?xml version="1.0" encoding="utf-8"?>\n'
    + "<response>\n"
    + `  <pg_status>${escape(body.pg_status)}</pg_status>\n`
    + `  <pg_description>${escape(body.pg_description)}</pg_description>\n`
    + `  <pg_salt>${escape(body.pg_salt)}</pg_salt>\n`
    + `  <pg_sig>${escape(body.pg_sig)}</pg_sig>\n`
    + "</response>";
}

/** Разбор их XML-ответа в плоский объект. Вложенности в ответах приёма нет. */
export function parseXml(xml) {
  const inner = String(xml).replace(/^[\s\S]*?<response>/, "").replace(/<\/response>[\s\S]*$/, "");
  const out = {};
  for (const m of inner.matchAll(/<([a-zA-Z0-9_]+)>([\s\S]*?)<\/\1>/g)) {
    if (!(m[1] in out)) {
      out[m[1]] = m[2]
        .replaceAll("&lt;", "<").replaceAll("&gt;", ">").replaceAll("&amp;", "&").trim();
    }
  }
  return out;
}

/**
 * Параметры из их callback'а.
 *
 * Они шлют три разных способа: обычную форму, multipart (так описан check_request) и GET.
 * Express в Cloud Functions разбирает только первый, а промахнуться здесь — значит не принять
 * уведомление об оплате и получать его снова каждые полчаса. Поэтому разбираем сами, по
 * content-type, и multipart тоже — он короткий и без файлов.
 *
 * @param {string} contentType
 * @param {Buffer|string} raw
 */
export function parseCallbackBody(contentType, raw) {
  const body = Buffer.isBuffer(raw) ? raw.toString("utf8") : String(raw || "");
  if (!body) return {};
  const type = String(contentType || "").toLowerCase();

  if (type.includes("multipart/form-data")) {
    const boundary = (type.match(/boundary=(?:"([^"]+)"|([^;]+))/) || [])
      .slice(1).find(Boolean);
    if (!boundary) return {};
    const out = {};
    for (const part of body.split(`--${boundary.trim()}`)) {
      const split = part.indexOf("\r\n\r\n");
      if (split < 0) continue;
      const name = (part.slice(0, split).match(/name="([^"]*)"/) || [])[1];
      if (!name || name in out) continue;
      out[name] = part.slice(split + 4).replace(/\r\n$/, "");
    }
    return out;
  }

  // application/x-www-form-urlencoded и всё остальное, что похоже на форму.
  const out = {};
  for (const [key, value] of new URLSearchParams(body)) {
    if (!(key in out)) out[key] = value;
  }
  return out;
}

/** Последний сегмент пути — имя скрипта для подписи. */
export function scriptNameOf(url) {
  const path = new URL(url).pathname;
  if (path.endsWith("/")) return "";
  return path.slice(path.lastIndexOf("/") + 1);
}
