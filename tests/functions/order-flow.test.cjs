// The order lifecycle and its 50 / 25 / 25 payout plan: who may take each step and when, what each
// step must carry (the live animal, the ready meat, the control weighing), the weighing's
// recalculation, cancelling only before the slaughter, completion by the buyer or by the clock,
// and a dispute holding the last part until staff decide.
//
// Runs against the local emulators under a demo- project id, so it can never touch production:
//   cd tests/functions && npm test
const path = require("path");
const fnModules = path.join(__dirname, "../../functions/node_modules");
const { initializeApp } = require(path.join(fnModules, "firebase-admin/lib/app/index.js"));
const { getFirestore, Timestamp } = require(path.join(fnModules, "firebase-admin/lib/firestore/index.js"));
const { getAuth } = require(path.join(fnModules, "firebase-admin/lib/auth/index.js"));

if (!process.env.FIRESTORE_EMULATOR_HOST || !process.env.FIREBASE_AUTH_EMULATOR_HOST) {
  console.error("refusing to run outside the emulator");
  process.exit(2);
}

initializeApp({ projectId: "demo-et" });
const db = getFirestore();
const auth = getAuth();
const FN = (name) => `http://127.0.0.1:5001/demo-et/europe-west3/${name}`;

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

async function call(name, token, data) {
  const r = await fetch(FN(name), {
    method: "POST",
    headers: { "content-type": "application/json", authorization: "Bearer " + token },
    body: JSON.stringify({ data }),
  });
  return r.json();
}

// A download URL as the Storage emulator hands it out, for a file in the farm's order folder.
const fileOf = (partnerId, orderId, name, kind) => ({
  kind, name,
  url: "http://127.0.0.1:9199/v0/b/demo-et.appspot.com/o/" + encodeURIComponent(`orders/${partnerId}/${orderId}/${name}`) + "?alt=media&token=t",
});

(async () => {
  const b = db.batch();
  b.set(db.doc("partners/fl_farm"), {
    uid: "fl_farm", displayName: "КХ Цикл", status: "verified", totalDeals: 0,
    storefront: { cutting: [], delivery: [{ id: "d1", city: "Астана", price: 5000 }], pickup: true },
  });
  b.set(db.doc("animals/fl_a1"), { partnerId: "fl_farm", breed: "Казахская белоголовая", type: "cattle" });
  b.set(db.doc("animals/fl_a1/documents/fl_d1"), {
    status: "approved", label: "Ветеринарная справка", fileUrl: "https://example.invalid/cert.pdf", partnerId: "fl_farm", animalId: "fl_a1",
  });
  b.set(db.doc("animals/fl_a1/documents/fl_d2"), {
    status: "rejected", label: "Старая справка", fileUrl: "https://example.invalid/old.pdf", partnerId: "fl_farm", animalId: "fl_a1",
  });
  const lot = { partnerId: "fl_farm", name: "Туша", status: "open", bookedShares: 0, totalShares: 2, pricePerKg: 3500, totalWeight: 120, pricePerShare: 210000, animalIds: ["fl_a1"] };
  ["FL1", "FL2", "FL3", "FL4"].forEach((id) => b.set(db.doc("lots/" + id), lot));
  b.set(db.doc("staff/fl_admin"), { uid: "fl_admin", role: "admin" });
  await b.commit();

  const farmer = await idTokenFor("fl_farm", "+15550009301");
  const buyer = await idTokenFor("fl_buyer", "+15550009302");
  const stranger = await idTokenFor("fl_stranger", "+15550009303");
  const admin = await idTokenFor("fl_admin", "+15550009304", { role: "admin" });

  const checks = [];
  const read = async (id) => (await db.doc("orders/" + id).get()).data();
  const act = (token, orderId, action, extra = {}) => call("updateOrderStatus", token, { orderId, action, ...extra });
  const expectErr = async (label, promise, status) => {
    const res = await promise;
    const pass = !!res.error && res.error.status === status;
    checks.push([pass, label, pass ? "" : JSON.stringify(res)]);
  };
  const expectOk = async (label, promise, verify) => {
    const res = await promise;
    let pass = !!res.result;
    let info = JSON.stringify(res);
    if (pass && verify) {
      try { pass = await verify(); } catch (e) { pass = false; info = String(e); }
    }
    checks.push([pass, label, pass ? "" : info]);
  };
  let key = 0;
  const place = async (lotId) => {
    const res = await call("createOrder", buyer, {
      lotId, format: "half", deliveryId: "d1", deliveryAddress: "Астана, ул. Тестовая 1", contactPhone: "+77000000000", idempotencyKey: "flow-key-" + (++key),
    });
    if (!res.result) throw new Error("order not placed: " + JSON.stringify(res));
    return res.result.orderId;
  };

  // ---- A: the whole road, with the weighing -------------------------------------------------
  const A = await place("FL1"); // 3 500 × 60 kg + 5 000 delivery = 215 000; the farm's share 193 500
  await expectErr("a stranger cannot touch the order", act(stranger, A, "accept"), "PERMISSION_DENIED");
  await expectErr("the buyer cannot accept for the farm", act(buyer, A, "accept"), "PERMISSION_DENIED");
  await expectErr("step 1 before accepting", act(farmer, A, "identify", { files: [fileOf("fl_farm", A, "a.jpg", "photo")] }), "FAILED_PRECONDITION");
  await expectOk("the farm accepts: the 50 % advance unlocks", act(farmer, A, "accept"), async () => {
    const o = await read(A);
    return o.status === "accepted" && o.payouts.net === 193500 && o.payouts.advance.amount === 96750
      && o.payouts.advance.status === "unlocked" && o.payouts.meat.status === "locked" && o.payouts.final.amount === 48375;
  });
  await expectErr("step 1 with no photo", act(farmer, A, "identify", { files: [] }), "INVALID_ARGUMENT");
  await expectErr("step 1 with a link from elsewhere", act(farmer, A, "identify", { files: [{ kind: "photo", url: "https://evil.example/x.jpg" }] }), "INVALID_ARGUMENT");
  await expectErr("step 1 with another farm's file", act(farmer, A, "identify", { files: [fileOf("someone_else", A, "a.jpg", "photo")] }), "INVALID_ARGUMENT");
  await expectOk("step 1: the live animal on video", act(farmer, A, "identify", { files: [fileOf("fl_farm", A, "animal.mp4", "video")] }), async () => {
    const o = await read(A);
    return o.status === "animal_selected" && o.steps.identify.files.length === 1 && o.steps.identify.files[0].kind === "video";
  });
  await expectErr("step 2 without the control weighing", act(farmer, A, "meat_ready", { files: [fileOf("fl_farm", A, "meat.jpg", "photo")] }), "INVALID_ARGUMENT");
  await expectOk("step 2: meat, a document, 62.4 kg on the scale - a surcharge of 8 400 and the second quarter",
    act(farmer, A, "meat_ready", {
      files: [fileOf("fl_farm", A, "meat.jpg", "photo")],
      documents: [fileOf("fl_farm", A, "vet.pdf", "doc")],
      scalePhoto: fileOf("fl_farm", A, "scale.jpg", "photo"),
      weightKg: 62.4,
    }),
    async () => {
      const o = await read(A);
      return o.status === "meat_ready" && o.weighing.weightKg === 62.4 && o.weighing.meat === 218400
        && o.weighing.total === 223400 && o.weighing.difference === 8400
        && o.payouts.net === 201060 && o.payouts.advance.amount === 96750
        && o.payouts.meat.amount === 52155 && o.payouts.meat.status === "unlocked" && o.payouts.final.amount === 52155
        && o.steps.meat.certificates.length === 1 && o.steps.meat.documents.length === 1;
    });
  await expectErr("the buyer cannot cancel after the slaughter", act(buyer, A, "cancel"), "FAILED_PRECONDITION");
  await expectOk("step 3: sent", act(farmer, A, "ship"), async () => (await read(A)).status === "shipped");
  await expectOk("step 4: handed over - the 3-hour window opens", act(farmer, A, "handover"), async () => {
    const o = await read(A);
    const left = o.autoCompleteAt.toMillis() - Date.now();
    return o.status === "delivered" && left > 2.9 * 3600e3 && left <= 3 * 3600e3;
  });
  await expectErr("auto-completion before the 3 hours are up", act(farmer, A, "autocomplete"), "FAILED_PRECONDITION");
  await expectErr("the farm cannot complete for the buyer", act(farmer, A, "complete"), "PERMISSION_DENIED");
  await expectOk("the buyer confirms: the deal completes and the last part unlocks", act(buyer, A, "complete"), async () => {
    const o = await read(A);
    const farm = (await db.doc("partners/fl_farm").get()).data();
    return o.status === "completed" && o.completedBy === "buyer" && o.payouts.final.status === "unlocked" && farm.totalDeals === 1;
  });

  // ---- B: cancelled before the slaughter ------------------------------------------------------
  const B = await place("FL2");
  await act(farmer, B, "accept");
  await expectOk("the buyer cancels an accepted order: the half returns to sale", act(buyer, B, "cancel"), async () => {
    const o = await read(B);
    const l = (await db.doc("lots/FL2").get()).data();
    return o.status === "cancelled" && o.cancelledBy === "buyer" && o.payouts.advance.status === "cancelled" && l.bookedShares === 0;
  });

  // ---- C: completed by the clock ---------------------------------------------------------------
  const C = await place("FL3");
  await act(farmer, C, "accept");
  await act(farmer, C, "identify", { files: [fileOf("fl_farm", C, "a.jpg", "photo")] });
  await act(farmer, C, "meat_ready", { files: [fileOf("fl_farm", C, "m.jpg", "photo")], weightKg: 60 });
  await act(farmer, C, "ship");
  await act(farmer, C, "handover");
  await db.doc("orders/" + C).update({ autoCompleteAt: Timestamp.fromMillis(Date.now() - 60000) });
  await expectOk("3 hours after handover the deal completes by itself", act(farmer, C, "autocomplete"), async () => {
    const o = await read(C);
    return o.status === "completed" && o.completedBy === "auto" && o.payouts.final.status === "unlocked" && o.weighing.difference === 0;
  });

  // ---- D: a dispute holds the last part ---------------------------------------------------------
  const D = await place("FL4");
  await act(farmer, D, "accept");
  await act(farmer, D, "identify", { files: [fileOf("fl_farm", D, "a.jpg", "photo")] });
  await act(farmer, D, "meat_ready", { files: [fileOf("fl_farm", D, "m.jpg", "photo")], weightKg: 60 });
  await expectErr("a dispute before the order is sent", act(buyer, D, "dispute", { description: "Запах, куски не те" }), "FAILED_PRECONDITION");
  await act(farmer, D, "ship");
  await expectErr("a dispute without a description", act(buyer, D, "dispute", { description: "" }), "INVALID_ARGUMENT");
  await expectOk("the buyer disputes at delivery: the last part is blocked", act(buyer, D, "dispute", { description: "Запах, куски не те" }), async () => {
    const o = await read(D);
    const d = (await db.doc("disputes/" + o.disputeId).get()).data();
    return o.status === "disputed" && o.payouts.final.status === "blocked" && d.orderId === D && d.status === "new" && d.uid === "fl_buyer";
  });
  await expectErr("a disputed deal cannot be confirmed", act(buyer, D, "complete"), "FAILED_PRECONDITION");
  {
    const o = await read(D);
    await expectOk("staff decide for the buyer: the order closes and the last part is withheld",
      call("reviewDispute", admin, { disputeId: o.disputeId, action: "resolve", outcome: "buyer", note: "Вернули разницу вручную" }),
      async () => {
        const after = await read(D);
        const farm = (await db.doc("partners/fl_farm").get()).data();
        return after.status === "completed" && after.completedBy === "dispute" && after.disputeOutcome === "buyer"
          && after.payouts.final.status === "withheld" && farm.totalDeals === 2;
      });
  }

  // ---- E: an order from before this flow -------------------------------------------------------
  await db.doc("orders/E_legacy").set({
    status: "created", partnerId: "fl_farm", buyerUid: "fl_buyer", lotId: "FL1", shares: 1, amount: 100000,
    statusHistory: [], payment: { status: "not_required" }, commission: { totalPct: 10 },
  });
  await expectOk("the old 'advance' still moves an old order", act(farmer, "E_legacy", "advance"), async () => (await read("E_legacy")).status === "confirmed");
  await expectOk("an old 'confirmed' order continues with step 1", act(farmer, "E_legacy", "identify", { files: [fileOf("fl_farm", "E_legacy", "a.jpg", "photo")] }),
    async () => (await read("E_legacy")).status === "animal_selected");

  for (const [pass, label, info] of checks) console.log(`  ${pass ? "ok  " : "FAIL"}  ${label}${pass ? "" : "  " + info}`);
  const failed = checks.filter((c) => !c[0]).length;
  console.log(`\norder lifecycle: ${checks.length - failed}/${checks.length} passed`);
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
