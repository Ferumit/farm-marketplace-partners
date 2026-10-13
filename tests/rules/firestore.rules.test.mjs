// Security-rules tests for the admin-panel change, run against the local Firestore emulator.
// A "demo-" project id keeps the emulator fully offline: nothing here can touch production.
import fs from "node:fs";
import { initializeTestEnvironment, assertSucceeds, assertFails } from "@firebase/rules-unit-testing";
import {
  doc, setDoc, getDoc, updateDoc, deleteDoc, collection, getDocs, collectionGroup, query, where,
  writeBatch,
} from "firebase/firestore";

const [host, port] = (process.env.FIRESTORE_EMULATOR_HOST || "127.0.0.1:8080").split(":");
const env = await initializeTestEnvironment({
  projectId: "demo-et",
  firestore: { rules: fs.readFileSync(new URL("../../firestore.rules", import.meta.url), "utf8"), host, port: Number(port) },
});

// The 17-key profile both apps and the site write on registration.
const profile = (uid, over = {}) => ({
  uid, phone: "+77000000000", role: "partner", displayName: "КХ Тест", iin: "123456789012",
  iban: null, country: null, documentUrl: null, status: "pending_review", createdAt: new Date(),
  avatarUrl: null, city: "Караганда", rating: 0, totalDeals: 0, walletBalance: 0,
  pendingBalance: 0, achievements: [], ...over,
});

// Seed with rules OFF - this is the state of the world, not something a client did.
await env.withSecurityRulesDisabled(async (ctx) => {
  const db = ctx.firestore();
  await setDoc(doc(db, "partners/farmer"), profile("farmer", { status: "verified", rating: 4.8, walletBalance: 500 }));
  await setDoc(doc(db, "clients/buyer"), { uid: "buyer", phone: "+77000000001", displayName: "Покупатель" });
  await setDoc(doc(db, "orders/o1"), { buyerUid: "buyer", partnerId: "farmer", status: "created", amount: 100 });
  await setDoc(doc(db, "animals/a1"), { partnerId: "farmer", breed: "Ангус" });
  await setDoc(doc(db, "animals/a1/documents/d1"), { status: "pending", partnerId: "farmer", animalId: "a1", uploadedAt: new Date(), reviewedBy: null });
  await setDoc(doc(db, "lots/booked"), { partnerId: "farmer", status: "open", bookedShares: 2, totalShares: 4 });
  await setDoc(doc(db, "lots/empty"), { partnerId: "farmer", status: "open", bookedShares: 0, totalShares: 4 });
  await setDoc(doc(db, "staff/admin"), { uid: "admin", role: "admin" });
  await setDoc(doc(db, "staff/ex-admin-record-only"), { uid: "ex-admin-record-only", role: "admin" });
  await setDoc(doc(db, "adminActions/x1"), { action: "partner.approve" });
});

const as = (uid, claims = {}) => env.authenticatedContext(uid, claims).firestore();
const farmer = as("farmer");
const newbie = as("newbie");
const stranger = as("stranger");
const buyer = as("buyer");
const admin = as("admin", { role: "admin" });
const revoked = as("revoked", { role: "admin" });                 // claim, but no staff record
const recordOnly = as("ex-admin-record-only");                     // record, but no claim

const results = [];
async function check(label, expect, fn) {
  try {
    await (expect === "ALLOW" ? assertSucceeds(fn()) : assertFails(fn()));
    results.push(["pass", expect, label]);
  } catch (e) {
    results.push(["FAIL", expect, label]);
  }
}

// ---- partners: registration exactly as the app and the site do it -------------------------
await check("new farm registers like the app (set, pending_review, zeros)", "ALLOW",
  () => setDoc(doc(newbie, "partners/newbie"), profile("newbie")));
await check("same farm registers again as the site does (merge, pending_review)", "ALLOW",
  () => setDoc(doc(as("newbie2"), "partners/newbie2"), profile("newbie2"), { merge: true }));
await check("new farm registers itself as 'verified'", "DENY",
  () => setDoc(doc(as("cheat1"), "partners/cheat1"), profile("cheat1", { status: "verified" })));
await check("new farm registers with walletBalance 100000", "DENY",
  () => setDoc(doc(as("cheat2"), "partners/cheat2"), profile("cheat2", { walletBalance: 100000 })));
await check("new farm registers with rating 5", "DENY",
  () => setDoc(doc(as("cheat3"), "partners/cheat3"), profile("cheat3", { rating: 5 })));

// ---- partners: edits -----------------------------------------------------------------------
await check("farm edits name/city/avatar (edit_partner_profile_screen)", "ALLOW",
  () => updateDoc(doc(farmer, "partners/farmer"), { displayName: "КХ Новое", city: "Астана", avatarUrl: "x" }));
// The real threat is a farm still UNDER REVIEW promoting itself. (Writing 'verified' onto a farm
// that already is verified changes nothing, so diff().affectedKeys() rightly lets it through.)
await check("farm under review promotes itself to 'verified'", "DENY",
  () => updateDoc(doc(newbie, "partners/newbie"), { status: "verified" }));
await check("farm under review marks itself 'active'", "DENY",
  () => updateDoc(doc(newbie, "partners/newbie"), { status: "active" }));
await check("verified farm re-writes its own status unchanged (harmless no-op)", "ALLOW",
  () => updateDoc(doc(farmer, "partners/farmer"), { status: "verified" }));
await check("farm raises its own rating", "DENY",
  () => updateDoc(doc(farmer, "partners/farmer"), { rating: 5 }));
await check("farm tops up its own wallet", "DENY",
  () => updateDoc(doc(farmer, "partners/farmer"), { walletBalance: 999999 }));
await check("farm writes its own review note", "DENY",
  () => updateDoc(doc(farmer, "partners/farmer"), { reviewNote: "всё ок" }));
await check("verified farm re-registers (non-merging set -> demotion bug)", "DENY",
  () => setDoc(doc(farmer, "partners/farmer"), profile("farmer")));
await check("stranger edits someone else's farm", "DENY",
  () => updateDoc(doc(stranger, "partners/farmer"), { displayName: "взлом" }));

// ---- staff: who counts --------------------------------------------------------------------
await check("admin (claim + record) reads any order", "ALLOW",
  () => getDoc(doc(admin, "orders/o1")));
await check("admin lists all orders", "ALLOW",
  () => getDocs(collection(admin, "orders")));
await check("revoked admin (claim, record deleted) reads an order", "DENY",
  () => getDoc(doc(revoked, "orders/o1")));
await check("record without claim reads an order", "DENY",
  () => getDoc(doc(recordOnly, "orders/o1")));
await check("admin reads a buyer's private profile", "ALLOW",
  () => getDoc(doc(admin, "clients/buyer")));
await check("stranger reads a buyer's private profile", "DENY",
  () => getDoc(doc(stranger, "clients/buyer")));
await check("buyer still reads own order", "ALLOW",
  () => getDoc(doc(buyer, "orders/o1")));

// ---- documents: the moderation queue --------------------------------------------------------
await check("admin lists pending documents across all animals", "ALLOW",
  () => getDocs(query(collectionGroup(admin, "documents"), where("status", "==", "pending"))));
await check("stranger lists documents across all animals", "DENY",
  () => getDocs(query(collectionGroup(stranger, "documents"), where("status", "==", "pending"))));
await check("admin approves a document DIRECTLY (must go via function + audit)", "DENY",
  () => updateDoc(doc(admin, "animals/a1/documents/d1"), { status: "approved" }));
await check("farmer still creates a pending document", "ALLOW",
  () => setDoc(doc(farmer, "animals/a1/documents/d2"), { status: "pending", partnerId: "farmer", animalId: "a1", reviewedBy: null }));
await check("farmer still reads own document", "ALLOW",
  () => getDoc(doc(farmer, "animals/a1/documents/d1")));
await check("stranger reads the document", "DENY",
  () => getDoc(doc(stranger, "animals/a1/documents/d1")));

// ---- audit trail and staff list ------------------------------------------------------------
await check("admin reads the audit trail", "ALLOW",
  () => getDocs(collection(admin, "adminActions")));
await check("admin edits an audit entry", "DENY",
  () => updateDoc(doc(admin, "adminActions/x1"), { action: "nothing happened" }));
await check("admin deletes an audit entry", "DENY",
  () => deleteDoc(doc(admin, "adminActions/x1")));
await check("stranger reads the audit trail", "DENY",
  () => getDocs(collection(stranger, "adminActions")));
await check("anyone makes themselves staff by writing staff/{uid}", "DENY",
  () => setDoc(doc(stranger, "staff/stranger"), { uid: "stranger", role: "admin" }));

// ---- regressions from earlier stages -------------------------------------------------------
await check("farmer unpublishes a BOOKED lot", "DENY",
  () => updateDoc(doc(farmer, "lots/booked"), { status: "draft" }));
await check("farmer unpublishes an EMPTY lot", "ALLOW",
  () => updateDoc(doc(farmer, "lots/empty"), { status: "draft" }));

// ---- regions and hub location --------------------------------------------------------------
await check("farm registers with a real region code", "ALLOW",
  () => setDoc(doc(as("reg1"), "partners/reg1"), profile("reg1", { regionCode: "KZ-35" })));
await check("farm registers with a made-up region code", "DENY",
  () => setDoc(doc(as("reg2"), "partners/reg2"), profile("reg2", { regionCode: "KZ-99" })));
await check("farm registers with its own publicLocation", "DENY",
  () => setDoc(doc(as("reg3"), "partners/reg3"), profile("reg3", { publicLocation: { lat: 49.8, lng: 73.1 } })));
await check("farm sets its region", "ALLOW",
  () => updateDoc(doc(farmer, "partners/farmer"), { regionCode: "KZ-71" }));
await check("farm sets a region as free text", "DENY",
  () => updateDoc(doc(farmer, "partners/farmer"), { regionCode: "Караганда" }));
await check("farm writes its public point directly", "DENY",
  () => updateDoc(doc(farmer, "partners/farmer"), { publicLocation: { lat: 49.80471, lng: 73.10938 } }));
await check("farm edits its name while a region is set", "ALLOW",
  () => updateDoc(doc(farmer, "partners/farmer"), { displayName: "КХ Новое 2" }));
await check("farm clears its region", "ALLOW",
  () => updateDoc(doc(farmer, "partners/farmer"), { regionCode: null }));

// private/identity - the IIN leaves the public profile
await check("new farm registers and files its IIN privately in one batch", "ALLOW", () => {
  const db = as("reg4");
  const b = writeBatch(db);
  b.set(doc(db, "partners/reg4"), profile("reg4", { iin: null, regionCode: "KZ-35" }));
  b.set(doc(db, "partners/reg4/private/identity"), { iin: "123456789012", updatedAt: new Date() });
  return b.commit();
});
await check("farm under review corrects its IIN", "ALLOW",
  () => setDoc(doc(as("reg4"), "partners/reg4/private/identity"), { iin: "210987654321", updatedAt: new Date() }));
await check("farm files an IIN that is not 12 digits", "DENY",
  () => setDoc(doc(as("reg4"), "partners/reg4/private/identity"), { iin: "12345", updatedAt: new Date() }));
await check("farm smuggles another field into identity", "DENY",
  () => setDoc(doc(as("reg4"), "partners/reg4/private/identity"), { iin: "123456789012", iban: "KZ00", updatedAt: new Date() }));
await check("VERIFIED farm changes its IIN on its own", "DENY",
  () => setDoc(doc(farmer, "partners/farmer/private/identity"), { iin: "210987654321", updatedAt: new Date() }));
await check("farm reads its own IIN", "ALLOW",
  () => getDoc(doc(as("reg4"), "partners/reg4/private/identity")));
await check("staff read a farm's IIN", "ALLOW",
  () => getDoc(doc(admin, "partners/reg4/private/identity")));
await check("stranger reads a farm's IIN", "DENY",
  () => getDoc(doc(stranger, "partners/reg4/private/identity")));
await check("anonymous visitor reads a farm's IIN", "DENY",
  () => getDoc(doc(as("anon-visitor", { firebase: { sign_in_provider: "anonymous" } }), "partners/reg4/private/identity")));
await check("revoked admin (claim, no record) reads a farm's IIN", "DENY",
  () => getDoc(doc(revoked, "partners/reg4/private/identity")));

// private/contact - the farm's email, its own business at any time
await check("new farm files its email privately in the registration batch", "ALLOW", () => {
  const db = as("reg5");
  const b = writeBatch(db);
  b.set(doc(db, "partners/reg5"), profile("reg5", { iin: null, regionCode: "KZ-35" }));
  b.set(doc(db, "partners/reg5/private/identity"), { iin: "123456789012", updatedAt: new Date() });
  b.set(doc(db, "partners/reg5/private/contact"), { email: "farm@example.kz", updatedAt: new Date() });
  return b.commit();
});
await check("VERIFIED farm changes its email", "ALLOW",
  () => setDoc(doc(farmer, "partners/farmer/private/contact"), { email: "new@example.kz", updatedAt: new Date() }));
await check("farm clears its email", "ALLOW",
  () => setDoc(doc(farmer, "partners/farmer/private/contact"), { email: null, updatedAt: new Date() }));
await check("farm saves something that is not an email", "DENY",
  () => setDoc(doc(farmer, "partners/farmer/private/contact"), { email: "not an email", updatedAt: new Date() }));
await check("farm smuggles another field into contact", "DENY",
  () => setDoc(doc(farmer, "partners/farmer/private/contact"), { email: "a@b.kz", iban: "KZ00", updatedAt: new Date() }));
await check("stranger writes a farm's email", "DENY",
  () => setDoc(doc(stranger, "partners/farmer/private/contact"), { email: "evil@example.kz", updatedAt: new Date() }));
await check("anonymous visitor writes its own contact", "DENY",
  () => setDoc(doc(as("anon-contact", { firebase: { sign_in_provider: "anonymous" } }), "partners/anon-contact/private/contact"), { email: "a@b.kz", updatedAt: new Date() }));
await check("stranger reads a farm's email", "DENY",
  () => getDoc(doc(stranger, "partners/farmer/private/contact")));
await check("staff read a farm's email", "ALLOW",
  () => getDoc(doc(admin, "partners/farmer/private/contact")));
await check("farm writes an arbitrary private document", "DENY",
  () => setDoc(doc(farmer, "partners/farmer/private/payout"), { iban: "KZ00", updatedAt: new Date() }));

// private/location and private/review - written by functions only
await check("farm writes its exact point directly", "DENY",
  () => setDoc(doc(farmer, "partners/farmer/private/location"), { lat: 49.8, lng: 73.1 }));
await check("farm writes its own review verdict", "DENY",
  () => setDoc(doc(newbie, "partners/newbie/private/review"), { decision: "approve" }));
await check("stranger reads a farm's exact point", "DENY",
  () => getDoc(doc(stranger, "partners/farmer/private/location")));
await check("staff read a farm's exact point", "ALLOW",
  () => getDoc(doc(admin, "partners/farmer/private/location")));
await check("farm reads its own review reason", "ALLOW",
  () => getDoc(doc(newbie, "partners/newbie/private/review")));

// lots carry a region too
await check("farmer creates a lot with a real region", "ALLOW",
  () => setDoc(doc(farmer, "lots/regional"), { partnerId: "farmer", status: "draft", bookedShares: 0, totalShares: 4, regionCode: "KZ-35", location: "Карагандинская область" }));
await check("farmer creates a lot with a made-up region", "DENY",
  () => setDoc(doc(farmer, "lots/badregion"), { partnerId: "farmer", status: "draft", bookedShares: 0, totalShares: 4, regionCode: "Mars" }));
await check("farmer moves a lot to a made-up region", "DENY",
  () => updateDoc(doc(farmer, "lots/regional"), { regionCode: "KZ-00" }));
await check("app-style lot with no region code still saves", "ALLOW",
  () => setDoc(doc(farmer, "lots/appstyle"), { partnerId: "farmer", status: "open", bookedShares: 0, totalShares: 4, location: "Қарағанды облысы" }));

// ---- a lot and its production steps, written together as the site does ------------------------
const step = (lotId, id, order) => ({ id, lotId, title: "Этап " + order, status: order === 1 ? "current" : "pending", order });
await check("farm creates a carcass lot and its steps in one batch", "ALLOW", () => {
  const b = writeBatch(farmer);
  b.set(doc(farmer, "lots/carcass1"), { partnerId: "farmer", name: "Туша", status: "draft", bookedShares: 0, totalShares: 2, pricePerKg: 3500, totalWeight: 120, regionCode: "KZ-35" });
  b.set(doc(farmer, "lots/carcass1/deliveries/step_1"), step("carcass1", "step_1", 1));
  b.set(doc(farmer, "lots/carcass1/deliveries/step_2"), step("carcass1", "step_2", 2));
  return b.commit();
});
await check("farm completes a step of its own lot", "ALLOW",
  () => updateDoc(doc(farmer, "lots/carcass1/deliveries/step_1"), { status: "completed" }));
await check("stranger writes a step of someone else's lot", "DENY",
  () => updateDoc(doc(stranger, "lots/carcass1/deliveries/step_1"), { status: "completed" }));
await check("stranger slips a step under someone else's lot while creating their own", "DENY", () => {
  const b = writeBatch(stranger);
  b.set(doc(stranger, "lots/strangers"), { partnerId: "stranger", name: "x", status: "draft", bookedShares: 0, totalShares: 2 });
  b.set(doc(stranger, "lots/carcass1/deliveries/step_9"), step("carcass1", "step_9", 9));
  return b.commit();
});

// ---- storefront, certified badge, legal details, farm certificates ----------------------------
const cutting = (n) => Array.from({ length: n }, (_, i) => ({ id: "c" + i, name: "Мүшелеу " + i, price: 15000 }));
await check("farm saves its storefront (description, cutting, delivery)", "ALLOW",
  () => updateDoc(doc(farmer, "partners/farmer"), { storefront: {
    description: "Откорм на пастбище", videoUrl: null, cutting: cutting(2),
    delivery: [{ id: "d1", city: "Караганда", price: 10000 }], pickup: true } }));
await check("farm stuffs 21 cutting options into its storefront", "DENY",
  () => updateDoc(doc(farmer, "partners/farmer"), { storefront: { description: "", cutting: cutting(21), delivery: [] } }));
await check("farm writes a 3001-character description", "DENY",
  () => updateDoc(doc(farmer, "partners/farmer"), { storefront: { description: "x".repeat(3001), cutting: [], delivery: [] } }));
await check("farm marks itself certified", "DENY",
  () => updateDoc(doc(farmer, "partners/farmer"), { certified: true }));
await check("new farm registers already certified", "DENY",
  () => setDoc(doc(as("cheat4"), "partners/cheat4"), profile("cheat4", { certified: true })));

const legal = (over = {}) => ({ form: "kh", legalName: "КХ «Тест»", address: "Карагандинская обл., с. Ботакара", updatedAt: new Date(), ...over });
await check("farm under review files its legal details", "ALLOW",
  () => setDoc(doc(newbie, "partners/newbie/private/legal"), legal()));
await check("farm under review corrects them", "ALLOW",
  () => setDoc(doc(newbie, "partners/newbie/private/legal"), legal({ legalName: "КХ «Тест-2»" })));
await check("VERIFIED farm without legal details adds them once", "ALLOW",
  () => setDoc(doc(farmer, "partners/farmer/private/legal"), legal()));
await check("VERIFIED farm then changes them on its own", "DENY",
  () => setDoc(doc(farmer, "partners/farmer/private/legal"), legal({ legalName: "Другое имя" })));
await check("legal details with an unknown legal form", "DENY",
  () => setDoc(doc(newbie, "partners/newbie/private/legal"), legal({ form: "ooo" })));
await check("legal details with a smuggled field", "DENY",
  () => setDoc(doc(newbie, "partners/newbie/private/legal"), legal({ iban: "KZ00" })));
await check("stranger reads a farm's legal details", "DENY",
  () => getDoc(doc(stranger, "partners/farmer/private/legal")));

// Счёт для выплат. В отличие от legal, меняется и после проверки: банк можно сменить, и ждать
// ради этого нового одобрения незачем. Формат проверяется строго - по счёту с опечаткой деньги
// не уйдут, а выглядеть он будет заполненным.
const bank = (over = {}) => ({
  iban: "KZ123456789012345678", bic: "HSBKKZKX", bankName: "Халык Банк", kbe: "17",
  updatedAt: new Date(), ...over,
});
await check("farm files its payout account", "ALLOW",
  () => setDoc(doc(newbie, "partners/newbie/private/bank"), bank()));
await check("VERIFIED farm changes its account without re-review", "ALLOW",
  () => setDoc(doc(farmer, "partners/farmer/private/bank"), bank({ bankName: "Другой банк" })));
await check("account with a non-Kazakh IBAN", "DENY",
  () => setDoc(doc(newbie, "partners/newbie/private/bank"), bank({ iban: "DE89370400440532013000" })));
await check("account with a too-short IBAN", "DENY",
  () => setDoc(doc(newbie, "partners/newbie/private/bank"), bank({ iban: "KZ1234" })));
await check("account with a malformed BIC", "DENY",
  () => setDoc(doc(newbie, "partners/newbie/private/bank"), bank({ bic: "HSBK" })));
await check("account with a three-digit KBe", "DENY",
  () => setDoc(doc(newbie, "partners/newbie/private/bank"), bank({ kbe: "170" })));
await check("account with a smuggled field", "DENY",
  () => setDoc(doc(newbie, "partners/newbie/private/bank"), bank({ balance: 1000000 })));
await check("farm writes an account into ANOTHER farm", "DENY",
  () => setDoc(doc(newbie, "partners/farmer/private/bank"), bank()));
await check("stranger reads a farm's payout account", "DENY",
  () => getDoc(doc(stranger, "partners/farmer/private/bank")));

// Доступ к онлайн-кассе: действующие ключи, которыми выбиваются налоговые документы под БИН
// хозяйства. Записать может только сам фермер, прочитать - НИКТО из клиентов, включая его
// самого и сотрудника. Это единственное место в базе с таким правилом, и проверяется оно
// здесь: ослабить его потом молча не выйдет.
// Значения выдуманные, и это важно: правила проверяют ФОРМУ записи, а не содержимое, поэтому
// настоящему паролю кассы тут делать нечего. Он уже один раз сюда попал и уехал в историю git.
const kassa = (over = {}) => ({
  znm: "TESTZNM-000", password: "не настоящий пароль, проверяется только форма", pin: "0000",
  updatedAt: new Date(), ...over,
});
await check("farm connects its cash register", "ALLOW",
  () => setDoc(doc(farmer, "partners/farmer/private/kassa"), kassa()));
await check("farm reads its own cash register access BACK", "DENY",
  () => getDoc(doc(farmer, "partners/farmer/private/kassa")));
await check("STAFF reads a farm's cash register access", "DENY",
  () => getDoc(doc(admin, "partners/farmer/private/kassa")));
await check("stranger reads a farm's cash register access", "DENY",
  () => getDoc(doc(stranger, "partners/farmer/private/kassa")));
await check("cash register without a PIN", "DENY",
  () => setDoc(doc(farmer, "partners/farmer/private/kassa"),
    { znm: "TESTZNM-000", password: "секрет", updatedAt: new Date() }));
await check("cash register with a letter in the PIN", "DENY",
  () => setDoc(doc(farmer, "partners/farmer/private/kassa"), kassa({ pin: "11a1" })));
await check("cash register with an empty password", "DENY",
  () => setDoc(doc(farmer, "partners/farmer/private/kassa"), kassa({ password: "" })));
await check("cash register with a malformed serial", "DENY",
  () => setDoc(doc(farmer, "partners/farmer/private/kassa"), kassa({ znm: "ЗНМ с пробелом" })));
await check("cash register with a smuggled field", "DENY",
  () => setDoc(doc(farmer, "partners/farmer/private/kassa"), kassa({ apiKey: "украденный" })));
await check("farm writes cash register access into ANOTHER farm", "DENY",
  () => setDoc(doc(newbie, "partners/farmer/private/kassa"), kassa()));
await check("farm disconnects its cash register", "ALLOW",
  () => deleteDoc(doc(farmer, "partners/farmer/private/kassa")));

// Та же касса без секретов: по ней экран и чек-лист узнают, что подключение есть. Читать её
// можно, но затащить туда пароль - нельзя, иначе смысл разделения теряется.
await check("farm records that a cash register is connected", "ALLOW",
  () => setDoc(doc(farmer, "partners/farmer/private/kassaInfo"),
    { znm: "TESTZNM-000", connectedAt: new Date() }));
await check("farm reads back WHICH register is connected", "ALLOW",
  () => getDoc(doc(farmer, "partners/farmer/private/kassaInfo")));
await check("a password smuggled into the readable record", "DENY",
  () => setDoc(doc(farmer, "partners/farmer/private/kassaInfo"),
    { znm: "TESTZNM-000", password: "секрет", connectedAt: new Date() }));
await check("stranger reads which register a farm connected", "DENY",
  () => getDoc(doc(stranger, "partners/farmer/private/kassaInfo")));

const cert = (over = {}) => ({ kind: "ses", status: "pending", partnerId: "farmer", reviewedBy: null, uploadedAt: new Date(), ...over });
await check("farm files a pending СЭС certificate", "ALLOW",
  () => setDoc(doc(farmer, "partners/farmer/documents/ses1"), cert()));
await check("farm files a certificate as already approved", "DENY",
  () => setDoc(doc(farmer, "partners/farmer/documents/ses2"), cert({ status: "approved" })));
await check("farm files a certificate of an unknown kind", "DENY",
  () => setDoc(doc(farmer, "partners/farmer/documents/x1"), cert({ kind: "passport" })));
await check("farm files a certificate into another farm", "DENY",
  () => setDoc(doc(stranger, "partners/farmer/documents/ses3"), cert({ partnerId: "stranger" })));
await check("farm approves its own certificate", "DENY",
  () => updateDoc(doc(farmer, "partners/farmer/documents/ses1"), { status: "approved" }));
await check("stranger reads a farm's certificate", "DENY",
  () => getDoc(doc(stranger, "partners/farmer/documents/ses1")));
await check("staff read a farm's certificate", "ALLOW",
  () => getDoc(doc(admin, "partners/farmer/documents/ses1")));
await check("staff list every pending document, farm certificates included", "ALLOW",
  () => getDocs(query(collectionGroup(admin, "documents"), where("status", "==", "pending"))));
await check("farm withdraws a pending certificate", "ALLOW",
  () => deleteDoc(doc(farmer, "partners/farmer/documents/ses1")));

// ---- anonymous sessions: every visitor of the public site - reads, never writes --------------
await env.withSecurityRulesDisabled(async (ctx) => {
  await setDoc(doc(ctx.firestore(), "chats/c1"), { participantIds: ["buyer", "farmer"], lotId: "empty" });
});
const anon = as("anon-site", { firebase: { sign_in_provider: "anonymous" } });
await check("anonymous visitor reads a verified farm", "ALLOW",
  () => getDoc(doc(anon, "partners/farmer")));
await check("anonymous visitor lists checked farms (the site's catalogue query)", "ALLOW",
  () => getDocs(query(collection(anon, "partners"), where("status", "in", ["verified", "active"]))));
await check("anonymous visitor looks up a farm that does not exist", "ALLOW",
  () => getDoc(doc(anon, "partners/no-such-farm")));
await check("anonymous visitor still reads the lot catalogue", "ALLOW",
  () => getDocs(collection(anon, "lots")));
await check("anonymous visitor reads a farm under review", "DENY",
  () => getDoc(doc(anon, "partners/newbie")));
await check("anonymous visitor lists every farm", "DENY",
  () => getDocs(collection(anon, "partners")));
await check("anonymous visitor creates an open lot", "DENY",
  () => setDoc(doc(anon, "lots/anon-lot"), { partnerId: "anon-site", name: "x", status: "open", bookedShares: 0, totalShares: 4 }));
await check("anonymous visitor registers a farm", "DENY",
  () => setDoc(doc(anon, "partners/anon-site"), profile("anon-site")));
await check("anonymous visitor creates an animal", "DENY",
  () => setDoc(doc(anon, "animals/anon-animal"), { partnerId: "anon-site", breed: "x" }));
await check("anonymous visitor posts to the feed", "DENY",
  () => setDoc(doc(anon, "feeds/anon-post"), { partnerId: "anon-site", type: "video", title: "x" }));
await check("anonymous visitor files a dispute", "DENY",
  () => setDoc(doc(anon, "disputes/anon-dispute"), { uid: "anon-site", lotId: "empty", description: "x" }));
await check("anonymous visitor writes a buyer profile", "DENY",
  () => setDoc(doc(anon, "clients/anon-site"), { uid: "anon-site" }));

// ---- farms that are not checked are private to themselves and staff ---------------------------
await check("signed-in stranger reads a farm under review", "DENY",
  () => getDoc(doc(stranger, "partners/newbie")));
await check("farm under review reads its own profile", "ALLOW",
  () => getDoc(doc(newbie, "partners/newbie")));
await check("staff read a farm under review", "ALLOW",
  () => getDoc(doc(admin, "partners/newbie")));
await check("staff list every farm", "ALLOW",
  () => getDocs(collection(admin, "partners")));

// ---- feeds and chats no longer take client writes ----------------------------------------------
await check("verified farm posts to the feed from a client", "DENY",
  () => setDoc(doc(farmer, "feeds/p1"), { partnerId: "farmer", type: "video", title: "x" }));
await check("anyone opens a chat with a farm", "DENY",
  () => setDoc(doc(stranger, "chats/c-new"), { participantIds: ["stranger", "farmer"] }));
await check("stranger writes themselves into someone else's chat", "DENY",
  () => updateDoc(doc(stranger, "chats/c1"), { participantIds: ["buyer", "farmer", "stranger"] }));
await check("stranger reads someone else's chat", "DENY",
  () => getDoc(doc(stranger, "chats/c1")));
await check("participant reads their chat", "ALLOW",
  () => getDoc(doc(buyer, "chats/c1")));
await check("participant posts under someone else's name", "DENY",
  () => setDoc(doc(buyer, "chats/c1/messages/m-spoof"), { senderId: "farmer", text: "..." }));
await check("participant posts as themselves", "ALLOW",
  () => setDoc(doc(buyer, "chats/c1/messages/m-ok"), { senderId: "buyer", text: "..." }));
await check("participant sends a message the way the partner app does (message + preview, one batch)", "ALLOW",
  () => {
    const b = writeBatch(farmer);
    b.set(doc(farmer, "chats/c1/messages/m-app"), { senderId: "farmer", senderName: "x", text: "hi", createdAt: new Date() });
    b.update(doc(farmer, "chats/c1"), { lastMessage: "hi", lastMessageAt: new Date() });
    return b.commit();
  });
await check("participant adds a third person to their chat", "DENY",
  () => updateDoc(doc(buyer, "chats/c1"), { participantIds: ["buyer", "farmer", "stranger"] }));
await check("participant rewrites the chat's lot", "DENY",
  () => updateDoc(doc(buyer, "chats/c1"), { lotId: "other" }));

// ---- the cart: the buyer's own, and nobody else's ------------------------------------------------
await check("buyer puts a carcass in their own cart", "ALLOW",
  () => setDoc(doc(buyer, "clients/buyer/cart/lot1__half"), {
    lotId: "lot1", format: "half", partnerId: "farmer", amount: 100, addedAt: new Date(),
  }));
await check("buyer reads their own cart", "ALLOW", () => getDocs(collection(buyer, "clients/buyer/cart")));
await check("buyer empties their own cart", "ALLOW", () => deleteDoc(doc(buyer, "clients/buyer/cart/lot1__half")));
await check("a stranger reads someone's cart", "DENY", () => getDocs(collection(stranger, "clients/buyer/cart")));
await check("a stranger writes into someone's cart", "DENY",
  () => setDoc(doc(stranger, "clients/buyer/cart/spam"), { lotId: "lot1", format: "half" }));
await check("staff read a buyer's cart", "DENY", () => getDocs(collection(admin, "clients/buyer/cart")));

// ---- push tokens: one per phone, owned by whoever is signed in on it ----------------------------
const TOKEN = "fcm_token_" + "x".repeat(40);
await check("buyer registers their own phone", "ALLOW",
  () => setDoc(doc(buyer, `clients/buyer/devices/${TOKEN}`), {
    token: TOKEN, platform: "android", updatedAt: new Date(),
  }));
await check("buyer takes their phone off at sign-out", "ALLOW",
  () => deleteDoc(doc(buyer, `clients/buyer/devices/${TOKEN}`)));
await check("farm registers its phone on its own record", "ALLOW",
  () => setDoc(doc(farmer, `partners/farmer/devices/${TOKEN}`), {
    token: TOKEN, platform: "android", updatedAt: new Date(),
  }));
await check("a token whose id and field disagree", "DENY",
  () => setDoc(doc(buyer, `clients/buyer/devices/${TOKEN}`), {
    token: "someone-elses-token", platform: "android", updatedAt: new Date(),
  }));
await check("anything else smuggled onto a device record", "DENY",
  () => setDoc(doc(buyer, `clients/buyer/devices/${TOKEN}`), {
    token: TOKEN, platform: "android", updatedAt: new Date(), uid: "someone-else",
  }));
await check("a stranger registers a phone under someone else's account", "DENY",
  () => setDoc(doc(stranger, `clients/buyer/devices/${TOKEN}`), {
    token: TOKEN, platform: "android", updatedAt: new Date(),
  }));
await check("a stranger lists the phones someone is signed in on", "DENY",
  () => getDocs(collection(stranger, "clients/buyer/devices")));
await check("staff list a buyer's phones", "DENY",
  () => getDocs(collection(admin, "clients/buyer/devices")));
await check("a stranger lists a farm's phones", "DENY",
  () => getDocs(collection(stranger, "partners/farmer/devices")));

// ---- reviews and joint purchases ----------------------------------------------------------------
await env.withSecurityRulesDisabled(async (ctx) => {
  const db = ctx.firestore();
  await setDoc(doc(db, "reviews/r-published"), {
    orderId: "r-published", partnerId: "farmer", buyerUid: "buyer", rating: 5, text: "Отлично",
    status: "published", createdAt: new Date(),
  });
  await setDoc(doc(db, "reviews/r-pending"), {
    orderId: "r-pending", partnerId: "farmer", buyerUid: "buyer", rating: 2, text: "Ждёт модерации",
    status: "pending", createdAt: new Date(),
  });
  await setDoc(doc(db, "groupBuys/g1"), {
    lotId: "empty", partnerId: "farmer", creatorUid: "buyer", size: 3, status: "open",
    members: [{ uid: "buyer", name: "Покупатель", amount: 100 }], memberUids: ["buyer"],
    amount: 300, perMember: [100, 100, 100], createdAt: new Date(),
  });
  await setDoc(doc(db, "groupBuys/g1/private/contact"), { deliveryAddress: "Алматы, ул. Тестовая 1", contactPhone: "+77010000001" });
  await setDoc(doc(db, "orders/o-group"), {
    buyerUid: "buyer", partnerId: "farmer", status: "created", amount: 300,
    memberUids: ["buyer", "stranger"],
  });
});
await check("anyone signed in reads a published review", "ALLOW", () => getDoc(doc(stranger, "reviews/r-published")));
await check("a stranger reads a review still on moderation", "DENY", () => getDoc(doc(stranger, "reviews/r-pending")));
await check("its author reads their own review on moderation", "ALLOW", () => getDoc(doc(buyer, "reviews/r-pending")));
await check("the farm reads a review about itself", "ALLOW", () => getDoc(doc(farmer, "reviews/r-pending")));
await check("staff read a review on moderation", "ALLOW", () => getDoc(doc(admin, "reviews/r-pending")));
await check("a browser writes a review of its own", "DENY",
  () => setDoc(doc(stranger, "reviews/forged"), { partnerId: "farmer", buyerUid: "stranger", rating: 5, status: "published" }));
await check("the farm publishes the review about itself", "DENY",
  () => updateDoc(doc(farmer, "reviews/r-pending"), { status: "published" }));
await check("the author rewrites their published review", "DENY",
  () => updateDoc(doc(buyer, "reviews/r-published"), { rating: 1 }));

await check("anyone with the link reads the group", "ALLOW", () => getDoc(doc(stranger, "groupBuys/g1")));
await check("a member reads the delivery address", "ALLOW", () => getDoc(doc(buyer, "groupBuys/g1/private/contact")));
await check("someone outside the group reads the address", "DENY", () => getDoc(doc(stranger, "groupBuys/g1/private/contact")));
await check("staff read the address", "ALLOW", () => getDoc(doc(admin, "groupBuys/g1/private/contact")));
await check("a browser writes itself into a group", "DENY",
  () => updateDoc(doc(stranger, "groupBuys/g1"), { memberUids: ["buyer", "stranger"] }));
await check("a browser creates a group of its own", "DENY",
  () => setDoc(doc(stranger, "groupBuys/forged"), { lotId: "empty", creatorUid: "stranger", size: 2, status: "open" }));

await check("a participant of a joint purchase follows its order", "ALLOW", () => getDoc(doc(stranger, "orders/o-group")));
await check("someone outside it still cannot", "DENY", () => getDoc(doc(newbie, "orders/o-group")));

// ---- notifications: read your own, mark them read, forge nothing -------------------------------
await env.withSecurityRulesDisabled(async (ctx) => {
  const db = ctx.firestore();
  await setDoc(doc(db, "notifications/n1"), {
    uid: "buyer", role: "buyer", kind: "order_accepted", title: "Хозяйство приняло заказ",
    body: "Туша №7", link: "/order?id=o1", orderId: "o1", read: false, createdAt: new Date(),
  });
});
await check("addressee reads their own notification", "ALLOW", () => getDoc(doc(buyer, "notifications/n1")));
await check("someone else reads it", "DENY", () => getDoc(doc(stranger, "notifications/n1")));
await check("addressee marks it read", "ALLOW",
  () => updateDoc(doc(buyer, "notifications/n1"), { read: true, readAt: new Date() }));
await check("addressee marks it unread again", "DENY", () => updateDoc(doc(buyer, "notifications/n1"), { read: false }));
await check("addressee rewrites the text", "DENY",
  () => updateDoc(doc(buyer, "notifications/n1"), { read: true, title: "Вам вернули деньги" }));
await check("addressee re-addresses it to someone else", "DENY",
  () => updateDoc(doc(buyer, "notifications/n1"), { read: true, uid: "stranger" }));
await check("a browser writes a notification of its own", "DENY",
  () => setDoc(doc(stranger, "notifications/forged"), {
    uid: "buyer", kind: "order_accepted", title: "Оплатите по ссылке", read: false, createdAt: new Date(),
  }));
await check("addressee deletes their notification", "DENY", () => deleteDoc(doc(buyer, "notifications/n1")));

await env.cleanup();
const failed = results.filter((r) => r[0] === "FAIL");
for (const [ok, want, label] of results) console.log(`  ${ok === "pass" ? "ok  " : "FAIL"}  [${want.padEnd(5)}] ${label}`);
console.log(`\n${results.length - failed.length}/${results.length} passed`);
process.exit(failed.length ? 1 : 0);
