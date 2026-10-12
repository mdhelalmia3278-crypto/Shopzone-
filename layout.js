import "./globals.css";

export const metadata = {
  title: "ShopZone | অনলাইন শপিং",
  description: "ShopZone — বাংলাদেশের জন্য জেনারেল ই-কমার্স স্টোর",
};

export default function RootLayout({ children }) {
  return <html lang="bn"><body>{children}</body></html>;
}
