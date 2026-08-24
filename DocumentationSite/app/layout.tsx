import type { Metadata } from "next";
import { headers } from "next/headers";
import "./globals.css";

const description = "A production-ready Swift networking stack for typed requests, shared work, resilience, authentication, offline delivery, realtime connections, and observability.";

export async function generateMetadata(): Promise<Metadata> {
  const requestHeaders = await headers();
  const host = requestHeaders.get("x-forwarded-host") ?? requestHeaders.get("host") ?? "localhost:3000";
  const protocol = requestHeaders.get("x-forwarded-proto") ?? (host.startsWith("localhost") ? "http" : "https");
  const base = new URL(`${protocol}://${host}`);
  const socialImage = new URL("/og.png", base).toString();

  return {
    metadataBase: base,
    title: { default: "NovaNetworkClient — Production networking for Swift", template: "%s · NovaNetworkClient" },
    description,
    icons: { icon: "/favicon.svg", shortcut: "/favicon.svg" },
    openGraph: { title: "NovaNetworkClient", description, type: "website", images: [{ url: socialImage, width: 1731, height: 909 }] },
    twitter: { card: "summary_large_image", title: "NovaNetworkClient", description, images: [socialImage] },
  };
}

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
