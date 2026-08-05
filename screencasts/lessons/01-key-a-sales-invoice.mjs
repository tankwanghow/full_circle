import { BASE_URL } from "../config.mjs";
import { login, recordCreated } from "../app.mjs";

export const id = "01";
export const title = "Key a Sales Invoice";
export const description =
  "Sign in, open a new sales invoice, choose the customer, add two goods lines, and save it.";

// Defaults match names that exist in a typical prod-restored full_circle_dev DB.
// Override via env if your data differs.
export const CUSTOMER = process.env.SCREENCAST_CUSTOMER ?? "Agri Channel";
export const GOOD_1 = process.env.SCREENCAST_GOOD_1 ?? "Egg Grade AA";
export const GOOD_2 = process.env.SCREENCAST_GOOD_2 ?? "Egg Tray";

export async function run(d) {
  await d.title("Lesson 1 — Key a Sales Invoice", "Full Circle · about 3 minutes");

  const companyId = await login(d);

  await d.say("This is your dashboard. Everything starts from here.");
  await d.click('a[href$="/Invoice"]');

  await d.say("This is the invoice list. Click New Invoice to start one.");
  await d.click('a[href$="/Invoice/new"]');

  await d.say("First, set the invoice date.");
  await d.fill("#invoice_invoice_date", today());

  await d.say("Now type the customer's name. Wait for the list, then pick from it.");
  await d.pickAutocomplete("#invoice_contact_name", CUSTOMER);
  await d.say("Notice the registration number and tax id fill in by themselves.");
  await d.highlight("#invoice_reg_no");

  await d.say("Add the first line. Type the goods name and pick it from the list.");
  await d.pickAutocomplete("#invoice_invoice_details_0_good_name", GOOD_1);
  await d.say("Enter the quantity.");
  await fillQty(d, 0, "10");
  await d.say("And the unit price. The line total works itself out.");
  await d.fill("#invoice_invoice_details_0_unit_price", "3.50");
  await d.highlight(".detail-amt-col");

  await d.say("Click Add Detail for a second line.");
  await d.click('a[phx-click="add_detail"]');
  await d.pickAutocomplete("#invoice_invoice_details_1_good_name", GOOD_2);
  await fillQty(d, 1, "5");
  await d.fill("#invoice_invoice_details_1_unit_price", "12.00");

  await d.say("Everything looks right. Save the invoice.");
  await d.click('#object-form button[type="submit"]');

  await d.page.waitForURL(/\/Invoice\/[0-9a-fA-F-]{36}\/edit/, { timeout: 20000 });
  await d.settle();

  await d.say("Saved. The system gives the invoice its own number.");
  await d.highlight("p.text-3xl");

  const docId = d.page.url().match(/\/Invoice\/([0-9a-fA-F-]{36})\/edit/)[1];
  const docNo = await d.page.locator("#invoice_invoice_no").inputValue();
  await recordCreated(id, companyId, docId, docNo);

  await d.say("You can open the print view any time from this screen.");
  await d.goto(`${BASE_URL}/companies/${companyId}/Invoice/${docId}/print?pre_print=false`);
  await d.pause(3000);

  await d.title("End of Lesson 1", "Next: recording a receipt");
}

function today() {
  const n = new Date();
  const p = (v) => String(v).padStart(2, "0");
  return `${n.getFullYear()}-${p(n.getMonth() + 1)}-${p(n.getDate())}`;
}

// Goods with packaging render quantity readonly and expect package_qty instead
// (detail_component.ex: unit_multiplier > 0). Tab after fill so LiveView
// recalculates quantity/amount before the next caption.
async function fillQty(d, index, value) {
  const qty = `#invoice_invoice_details_${index}_quantity`;
  const pack = `#invoice_invoice_details_${index}_package_qty`;
  const readonly = await d.page.locator(qty).getAttribute("readonly");
  const sel = readonly !== null ? pack : qty;
  await d.fill(sel, value);
  await d.page.locator(sel).press("Tab");
  await d.settle();
}
