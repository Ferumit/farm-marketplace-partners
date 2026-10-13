// reviewDispute: only live staff act, only along the allowed moves, a closing decision carries the
// note the buyer will read - and every change, and only a change, leaves an audit record.
//
// Runs against the local emulators under a demo- project id, so it can never touch production:
//   cd tests/functions && npm test
const path = require("path");
const fnModules = path.join(__dirname, "../../functions/node_modules");
const { initializeApp } = require(path.join(fnModules, "firebase-admin/lib/app/index.js"));
const { getFirestore } = require(path.join(fnModules, "firebase-admin/lib/firestore/index.js"));
const { getAuth } = require(path.join(fnModules, "firebase-admin/lib/auth/index.js"));

if (!process.env.FIRESTORE_EMULATOR_HOST || !process.env.FIREBASE_AUTH_EMULATOR_HOST) {
  console.error("refusing to run outside the emulator");
  process.exit(2);
}

initializeApp({ projectId: "demo-et" });
const db = getFirestore();
const auth = getAuth();
const FN = "http://127.0.0.1:5001/demo-et/europe-west3/reviewDispute";

async function idTokenFor(uid, phone, claims = {}) {
  await auth.createUser({ uid, phoneNumber: phone }).catch(() => {});
  const custom = await auth.createCustomToken(uid, claims);
  const r = await fetch(`http://${process.env.FIREBASE_AUTH_EMULATOR_HOST}/identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key=fake`, {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ token: custom, returnSecureToken: true }),
  });
  const j = await r.json();
  if (!j.idToken) throw new Error("no token: " + JSON.stringify(j));
  return j.idToken;
}

async function review(token, data) {
  const r = await fetch(FN, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: "Bearer " + token },
    body: JSON.stringify({ data }),
  });
  return r.json();
}

(async () => {
  const b = db.batch();
  b.set(db.doc("staff/dsp_admin"), { uid: "dsp_admin", role: "admin" });
  b.set(db.doc("staff/dsp_support"), { uid: "dsp_support", role: "support" });
  const dispute = (status) => ({
    uid: "dsp_buyer", lotId: "L1", description: "Запах при приёмке", mediaUrl: null, status, createdAt: new Date(),
  });
  b.set(db.doc("disputes/D_new"), dispute("new"));
  b.set(db.doc("disputes/D_new2"), dispute("new"));
  b.set(db.doc("disputes/D_review"), dispute("in_review"));
  b.set(db.doc("disputes/D_done"), dispute("resolved"));
  await b.commit();

  const admin = await idTokenFor("dsp_admin", "+15550008001", { role: "admin" });
  const support = await idTokenFor("dsp_support", "+15550008002", { role: "support" });
  const buyer = await idTokenFor("dsp_buyer", "+15550008003");
  const ghost = await idTokenFor("dsp_ghost", "+15550008004", { role: "admin" }); // claim, no staff record

  const checks = [];
  const expectError = async (label, token, data, status) => {
    const res = await review(token, data);
    const ok = !!res.error && res.error.status === status;
    checks.push([ok, label, ok ? "" : JSON.stringify(res)]);
  };
  const expectOk = async (label, token, data, verify) => {
    const res = await review(token, data);
    let ok = !!res.result;
    if (ok && verify) ok = await verify();
    checks.push([ok, label, ok ? "" : JSON.stringify(res)]);
  };
  const read = async (id) => (await db.doc("disputes/" + id).get()).data();

  await expectError("a buyer cannot take a dispute", buyer,
    { disputeId: "D_new", action: "take" }, "PERMISSION_DENIED");
  await expectError("a role claim without a staff record is refused", ghost,
    { disputeId: "D_new", action: "take" }, "PERMISSION_DENIED");
  await expectOk("support takes a new dispute", support, { disputeId: "D_new", action: "take" },
    async () => { const d = await read("D_new"); return d.status === "in_review" && d.handledBy === "dsp_support"; });
  await expectError("taking it a second time is refused", support,
    { disputeId: "D_new", action: "take" }, "FAILED_PRECONDITION");
  await expectError("closing without a note for the buyer is refused", admin,
    { disputeId: "D_review", action: "resolve", outcome: "buyer", note: "" }, "INVALID_ARGUMENT");
  await expectError("closing with an unknown outcome is refused", admin,
    { disputeId: "D_review", action: "resolve", outcome: "refund-all", note: "Вернули деньги" }, "INVALID_ARGUMENT");
  await expectOk("admin closes a dispute in review, with a note", admin,
    { disputeId: "D_review", action: "resolve", outcome: "buyer", note: "Вернули 50 000 ₸ на карту" },
    async () => {
      const d = await read("D_review");
      return d.status === "resolved" && d.resolution?.outcome === "buyer" && d.resolution?.note === "Вернули 50 000 ₸ на карту";
    });
  await expectOk("a new dispute can be closed straight away", support,
    { disputeId: "D_new2", action: "resolve", outcome: "withdrawn", note: "Покупатель отозвал претензию" },
    async () => (await read("D_new2")).status === "resolved");
  await expectError("a closed dispute stays closed", admin,
    { disputeId: "D_done", action: "resolve", outcome: "partner", note: "Передумали" }, "FAILED_PRECONDITION");
  await expectError("an unknown dispute", admin, { disputeId: "nope", action: "take" }, "NOT_FOUND");

  const rows = (await db.collection("adminActions").where("targetType", "==", "dispute").get()).docs.map((d) => d.data());
  const ids = rows.map((r) => r.targetId).sort().join(",");
  checks.push([ids === "D_new,D_new2,D_review", "every change - and only a change - left an audit record",
    JSON.stringify(rows.map((r) => [r.action, r.targetId]))]);

  for (const [ok, label, info] of checks) console.log(`  ${ok ? "ok  " : "FAIL"}  ${label}${ok ? "" : "  " + info}`);
  const failed = checks.filter((c) => !c[0]).length;
  console.log(`\ndisputes: ${checks.length - failed}/${checks.length} passed`);
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
