// Reviews: who may leave one and when, that a deal can be reviewed once, and that a farm's public
// rating is exactly the average of the reviews a moderator published - never of anything else.
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

const fileOf = (partnerId, orderId, name, kind) => ({
  kind, name,
  url: "http://127.0.0.1:9199/v0/b/demo-et.appspot.com/o/" + encodeURIComponent(`orders/${partnerId}/${orderId}/${name}`) + "?alt=media&token=t",
});

(async () => {
  const b = db.batch();
  b.set(db.doc("partners/rv_farm"), {
    uid: "rv_farm", displayName: "КХ Отзыв", status: "verified", totalDeals: 0, rating: 0,
    storefront: { cutting: [], delivery: [], pickup: true },
  });
  b.set(db.doc("clients/rv_buyer"), { uid: "rv_buyer", displayName: "Асхат", phone: "+77010000001" });
  const lot = {
    partnerId: "rv_farm", name: "Туша отзыв", status: "open", bookedShares: 0, totalShares: 2,
    pricePerKg: 3000, totalWeight: 100, pricePerShare: 150000, animalIds: [],
  };
  ["RV1", "RV2", "RV3"].forEach((id) => b.set(db.doc("lots/" + id), lot));
  b.set(db.doc("staff/rv_admin"), { uid: "rv_admin", role: "admin" });
  await b.commit();

  const farmer = await idTokenFor("rv_farm", "+15550009501");
  const buyer = await idTokenFor("rv_buyer", "+15550009502");
  const stranger = await idTokenFor("rv_stranger", "+15550009503");
  const admin = await idTokenFor("rv_admin", "+15550009504", { role: "admin" });

  const checks = [];
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
      try { pass = await verify(res.result); } catch (e) { pass = false; info = String(e); }
    }
    checks.push([pass, label, pass ? "" : info]);
  };

  let key = 0;
  const act = (token, orderId, action, extra = {}) => call("updateOrderStatus", token, { orderId, action, ...extra });
  const place = async (lotId) => {
    const res = await call("createOrder", buyer, {
      lotId, format: "half", deliveryId: "pickup", contactPhone: "+77010000001",
      idempotencyKey: "review-key-" + (++key),
    });
    if (!res.result) throw new Error("order not placed: " + JSON.stringify(res));
    return res.result.orderId;
  };
  const complete = async (orderId) => {
    await act(farmer, orderId, "accept");
    await act(farmer, orderId, "identify", { files: [fileOf("rv_farm", orderId, "a.jpg", "photo")] });
    await act(farmer, orderId, "meat_ready", { files: [fileOf("rv_farm", orderId, "m.jpg", "photo")], weightKg: 50 });
    await act(farmer, orderId, "ship");
    await act(farmer, orderId, "handover");
    await act(buyer, orderId, "complete");
  };
  const farmRating = async () => (await db.doc("partners/rv_farm").get()).data();

  // ---- a review belongs to a completed deal, and to its buyer ---------------------------------
  const A = await place("RV1");
  await expectErr("отзыв до завершения сделки", call("submitReview", buyer, { orderId: A, rating: 5, text: "Отлично" }), "FAILED_PRECONDITION");
  await complete(A);
  await expectErr("отзыв от постороннего", call("submitReview", stranger, { orderId: A, rating: 5, text: "Отлично" }), "PERMISSION_DENIED");
  await expectErr("оценка вне 1..5", call("submitReview", buyer, { orderId: A, rating: 7, text: "Отлично" }), "INVALID_ARGUMENT");
  await expectOk("покупатель оставляет отзыв — он ждёт модерации",
    call("submitReview", buyer, { orderId: A, rating: 5, text: "Мясо отличное, фермер на связи" }), async () => {
      const r = (await db.doc("reviews/" + A).get()).data();
      const o = (await db.doc("orders/" + A).get()).data();
      const farm = await farmRating();
      return r.status === "pending" && r.rating === 5 && r.partnerId === "rv_farm" && r.buyerName === "Асхат"
        && o.reviewId === A && (farm.rating || 0) === 0;
    });
  await expectErr("второй отзыв по той же сделке", call("submitReview", buyer, { orderId: A, rating: 1, text: "Передумал" }), "FAILED_PRECONDITION");

  // ---- moderation moves the rating, and only published reviews count ---------------------------
  await expectErr("модерация не сотрудником", call("moderateReview", buyer, { reviewId: A, decision: "approve" }), "PERMISSION_DENIED");
  await expectOk("модератор публикует: рейтинг хозяйства становится 5", call("moderateReview", admin, { reviewId: A, decision: "approve" }), async () => {
    const r = (await db.doc("reviews/" + A).get()).data();
    const farm = await farmRating();
    return r.status === "published" && farm.rating === 5 && farm.reviewsCount === 1;
  });

  const B = await place("RV2");
  await complete(B);
  await call("submitReview", buyer, { orderId: B, rating: 4, text: "Задержали на день" });
  await expectOk("второй опубликованный отзыв усредняет рейтинг до 4.5", call("moderateReview", admin, { reviewId: B, decision: "approve" }), async () => {
    const farm = await farmRating();
    return farm.rating === 4.5 && farm.reviewsCount === 2;
  });

  const C = await place("RV3");
  await complete(C);
  await call("submitReview", buyer, { orderId: C, rating: 1, text: "Не то" });
  await expectErr("отказ без причины", call("moderateReview", admin, { reviewId: C, decision: "reject" }), "INVALID_ARGUMENT");
  await expectOk("отклонённый отзыв не меняет рейтинг и объясняет причину автору",
    call("moderateReview", admin, { reviewId: C, decision: "reject", note: "Оскорбления, перепишите без них" }), async () => {
      const r = (await db.doc("reviews/" + C).get()).data();
      const farm = await farmRating();
      const notes = await db.collection("notifications").where("uid", "==", "rv_buyer").get();
      const latest = notes.docs.map((d) => d.data()).sort((a, b) => b.createdAt.toMillis() - a.createdAt.toMillis())[0];
      return r.status === "rejected" && farm.rating === 4.5 && farm.reviewsCount === 2
        && latest.kind === "review_moderated" && latest.body.includes("Оскорбления");
    });

  for (const [pass, label, info] of checks) console.log(`  ${pass ? "ok  " : "FAIL"}  ${label}${pass ? "" : "  " + info}`);
  const failed = checks.filter((c) => !c[0]).length;
  console.log(`\nreviews: ${checks.length - failed}/${checks.length} passed`);
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
