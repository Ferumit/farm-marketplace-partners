// Storage security-rules tests, run against the local Storage emulator under a demo- project id,
// so nothing here can touch the production bucket.
import fs from "node:fs";
import { initializeTestEnvironment, assertSucceeds, assertFails } from "@firebase/rules-unit-testing";
import { ref, uploadBytes, getMetadata, deleteObject } from "firebase/storage";

const [host, port] = (process.env.FIREBASE_STORAGE_EMULATOR_HOST || "127.0.0.1:9199").split(":");
const env = await initializeTestEnvironment({
  projectId: "demo-et",
  storage: { rules: fs.readFileSync(new URL("../../storage.rules", import.meta.url), "utf8"), host, port: Number(port) },
});

const bytes = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4]);
const jpeg = { contentType: "image/jpeg" };
const as = (uid, claims = {}) => env.authenticatedContext(uid, claims).storage();
const farmer = as("farmer");
const stranger = as("stranger");
const buyer = as("buyer");
const anon = as("anon-site", { firebase: { sign_in_provider: "anonymous" } });
const admin = as("admin", { role: "admin" });
const up = (st, path, meta = jpeg) => uploadBytes(ref(st, path), bytes, meta);

// Existing files to read and delete, put there with rules off.
await env.withSecurityRulesDisabled(async (ctx) => {
  const st = ctx.storage();
  await uploadBytes(ref(st, "lots/farmer/cover-old.jpg"), bytes, jpeg);
  await uploadBytes(ref(st, "disputes/buyer/lot1_evidence.jpg"), bytes, jpeg);
  await uploadBytes(ref(st, "documents/farmer/a1/d1.pdf"), bytes, { contentType: "application/pdf" });
});

const results = [];
async function check(label, expect, fn) {
  try {
    await (expect === "ALLOW" ? assertSucceeds(fn()) : assertFails(fn()));
    results.push(["pass", expect, label]);
  } catch (e) {
    results.push(["FAIL", expect, label]);
  }
}

// ---- lot covers and delivery-step photos: the paths the site and the app actually use ----------
await check("farm uploads a lot cover (lots/{uid}/{file})", "ALLOW", () => up(farmer, "lots/farmer/1700000000000.jpg"));
await check("farm uploads a delivery-step photo (lots/{uid}/steps/...)", "ALLOW", () => up(farmer, "lots/farmer/steps/lotA_step_3_1700.jpg"));
await check("farm uploads into another farm's lot folder", "DENY", () => up(stranger, "lots/farmer/evil.jpg"));
await check("farm uploads a non-image as a lot cover", "DENY", () => up(farmer, "lots/farmer/x.html", { contentType: "text/html" }));
await check("anyone signed in reads a lot cover", "ALLOW", () => getMetadata(ref(buyer, "lots/farmer/cover-old.jpg")));
await check("farm deletes its own old cover", "ALLOW", () => deleteObject(ref(farmer, "lots/farmer/cover-old.jpg")));

// ---- anonymous sessions never upload ---------------------------------------------------------------
await check("anonymous visitor uploads into its own lot folder", "DENY", () => up(anon, "lots/anon-site/x.jpg"));
await check("anonymous visitor uploads an animal photo", "DENY", () => up(anon, "animals/anon-site/x.jpg"));
await check("anonymous visitor uploads a document", "DENY", () => up(anon, "documents/anon-site/a/x.pdf", { contentType: "application/pdf" }));
await check("anonymous visitor uploads dispute evidence", "DENY", () => up(anon, "disputes/anon-site/x.jpg"));

// ---- animals, avatars -------------------------------------------------------------------------------
await check("farm uploads an animal photo", "ALLOW", () => up(farmer, "animals/farmer/1700.jpg"));
await check("farm uploads an animal photo into another farm's folder", "DENY", () => up(stranger, "animals/farmer/x.jpg"));
await check("partner app avatar (users/{uid}/avatar.jpg)", "ALLOW", () => up(farmer, "users/farmer/avatar.jpg"));
await check("avatar into someone else's folder", "DENY", () => up(stranger, "users/farmer/avatar.jpg"));
await check("buyer app avatar (avatars/clients/{uid}.jpg)", "ALLOW", () => up(buyer, "avatars/clients/buyer.jpg"));
await check("buyer app avatar under someone else's name", "DENY", () => up(stranger, "avatars/clients/buyer.jpg"));

// ---- the farm's storefront media ------------------------------------------------------------------
const video = { contentType: "video/mp4" };
await check("farm uploads its slaughterhouse video", "ALLOW", () => up(farmer, "farms/farmer/video/1700.mp4", video));
await check("farm uploads a cover still for it", "ALLOW", () => up(farmer, "farms/farmer/poster/1700.jpg"));
await check("farm uploads a video into another farm's folder", "DENY", () => up(stranger, "farms/farmer/video/x.mp4", video));
await check("anonymous visitor uploads a video", "DENY", () => up(anon, "farms/anon-site/video/x.mp4", video));
await check("farm uploads a web page as its video", "DENY", () => up(farmer, "farms/farmer/video/x.html", { contentType: "text/html" }));
await check("any visitor reads the storefront video", "ALLOW", () => getMetadata(ref(anon, "farms/farmer/video/1700.mp4")));

// ---- files of an order's steps ------------------------------------------------------------------
await check("farm uploads a photo of the live animal for its order", "ALLOW", () => up(farmer, "orders/farmer/o1/1700-animal.jpg"));
await check("farm uploads a video of the live animal", "ALLOW", () => up(farmer, "orders/farmer/o1/1700-animal.mp4", { contentType: "video/mp4" }));
await check("farm uploads a PDF document for its order", "ALLOW", () => up(farmer, "orders/farmer/o1/1700-vet.pdf", { contentType: "application/pdf" }));
await check("farm uploads into another farm's order folder", "DENY", () => up(stranger, "orders/farmer/o1/x.jpg"));
await check("anonymous visitor uploads an order file", "DENY", () => up(anon, "orders/anon-site/o1/x.jpg"));
await check("farm uploads a web page as an order file", "DENY", () => up(farmer, "orders/farmer/o1/x.html", { contentType: "text/html" }));

// ---- documents ---------------------------------------------------------------------------------------
await check("farm uploads a vet document (PDF)", "ALLOW", () => up(farmer, "documents/farmer/a1/d2.pdf", { contentType: "application/pdf" }));
await check("reviewer reads a farm's document", "ALLOW", () => getMetadata(ref(admin, "documents/farmer/a1/d1.pdf")));
await check("stranger reads a farm's document", "DENY", () => getMetadata(ref(stranger, "documents/farmer/a1/d1.pdf")));

// ---- dispute evidence: the read-back the site does right after uploading used to be refused -------
await check("buyer uploads dispute evidence", "ALLOW", () => up(buyer, "disputes/buyer/lot1_1700_photo.jpg"));
await check("buyer reads back their own evidence (download link)", "ALLOW", () => getMetadata(ref(buyer, "disputes/buyer/lot1_evidence.jpg")));
await check("staff read dispute evidence", "ALLOW", () => getMetadata(ref(admin, "disputes/buyer/lot1_evidence.jpg")));
await check("stranger reads someone's dispute evidence", "DENY", () => getMetadata(ref(stranger, "disputes/buyer/lot1_evidence.jpg")));
await check("buyer deletes their evidence", "DENY", () => deleteObject(ref(buyer, "disputes/buyer/lot1_evidence.jpg")));

await env.cleanup();
const failed = results.filter((r) => r[0] === "FAIL");
for (const [ok, want, label] of results) console.log(`  ${ok === "pass" ? "ok  " : "FAIL"}  [${want.padEnd(5)}] ${label}`);
console.log(`\nstorage: ${results.length - failed.length}/${results.length} passed`);
process.exit(failed.length ? 1 : 0);
