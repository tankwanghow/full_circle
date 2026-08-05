import fs from "node:fs/promises";
import { BASE_URL, CREATED_LOG, credentials } from "./config.mjs";

const COMPANY_URL = /\/companies\/([0-9a-fA-F-]{36})\/dashboard/;

export async function login(d) {
  const { email, password } = credentials();

  await d.goto(`${BASE_URL}/users/log_in`);
  await d.say("Start by signing in with your email and password.");
  await d.type("#user_email", email);
  await d.type("#user_password", password);
  await d.click('#login_form button[type="submit"]');

  await d.page.waitForURL(/\/companies(\/|$)/, { timeout: 20000 });

  const url = d.page.url();
  const match = url.match(COMPANY_URL);
  if (!match) {
    throw new Error(
      `Expected to land on a company dashboard but landed on ${url}. ` +
        `The screencast account needs a default company — set one in Companies before recording.`
    );
  }
  return match[1];
}

export async function recordCreated(lessonId, companyId, docId, docNo) {
  const line = [new Date().toISOString(), lessonId, companyId, docId, docNo].join("\t") + "\n";
  await fs.appendFile(CREATED_LOG, line, "utf8");
}
