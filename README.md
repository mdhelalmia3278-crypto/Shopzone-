# ShopZone — Live e-commerce starter

A deployable Next.js + Supabase starter for a Bangladesh-focused general store.

## Included
- Product listing/search/category filtering
- Cart and checkout
- Customer sign-in/sign-up using Supabase Auth
- Supabase Postgres schema, RLS policies, and admin role
- Admin product create/edit/delete and order status management
- Cash on delivery and manual bKash/Nagad payment instructions
- Free-tier deployment path: Supabase + Vercel

## Important payment note
bKash/Nagad are shown as **manual payment** methods in this starter. The customer pays using your merchant/personal payment instructions and submits a transaction ID; an admin verifies it. This is not an automated payment gateway. Automated payments require an approved merchant account and official gateway credentials/webhooks. Never ask customers to enter a PIN or OTP on your website.

## 1. Create Supabase project
1. Create a project at https://supabase.com
2. Open SQL Editor and run `supabase/schema.sql`.
3. In Authentication settings, enable Email provider. For production, configure email SMTP and set the Site URL to your deployed URL.
4. Copy Project URL and anon/public key into `.env.local`.
5. Register your own account through the website.
6. In Supabase SQL Editor, promote your account to admin using the SQL in `supabase/make-admin.sql` after replacing the email. Do not expose service-role keys in the browser.

## 2. Run locally
Install Node.js 20+.
```bash
cp .env.example .env.local
npm install
npm run dev
```
Open http://localhost:3000

## 3. Deploy free
1. Push this folder to a private/public GitHub repository.
2. Import the repository at https://vercel.com.
3. Add `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_ANON_KEY` in Vercel Project Settings → Environment Variables.
4. Deploy. Add the resulting Vercel URL to Supabase Auth → URL Configuration → Site URL and Redirect URLs.
5. Test signup/login, product creation as admin, checkout, and order status updates.

Free-tier limits and terms can change. A free deployment is suitable for a prototype/small start, but availability, email delivery, backups, and production capacity are not guaranteed.

## 4. Admin access
Register your account on the deployed website, then run `supabase/make-admin.sql` with your exact account email substituted. Only do this in your own Supabase project. Admin role is stored in the database and checked by RLS, not by a client-side flag.

## 5. bKash/Nagad manual payment
In `app/page.js`, edit the merchant/payment instructions to your verified payment account. Customers enter a transaction reference at checkout; admin must independently verify the payment before fulfilling. Never mark a payment paid just because a customer typed a reference.

## Production checklist
- Set up a custom domain when ready.
- Configure SMTP and test email confirmation/password reset.
- Use official bKash/Nagad merchant gateway if you need automatic confirmation.
- Add shipping rates, refund/privacy/terms pages, customer support contact and order notifications.
- Test RLS using a non-admin account.
- Do not commit `.env.local`, access tokens, or service-role keys.
