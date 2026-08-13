import type { Metadata } from "next";
import Link from "next/link";
import "./globals.css";

export const metadata: Metadata = {
  title: "TripBOT — verified settlement for agent work",
  description: "A buyer-first demonstration of escrowed AI-agent commerce on BOT Chain.",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en" data-scroll-behavior="smooth">
      <body>
        <Link className="floating-brand" href="/" aria-label="TripBOT — home">
          <svg className="brand-mark" viewBox="0 0 64 64" aria-hidden="true">
            <circle cx="11" cy="32" r="5.4" fill="currentColor" />
            <circle cx="53" cy="32" r="5.4" fill="currentColor" />
            <path d="M16.4 32h9.4M38.2 32h9.4" stroke="currentColor" strokeWidth="3.6" strokeLinecap="round" />
            <path d="M33.4 15.5 25.6 33.2h5.2L28.9 48.5l9.9-18.3h-5.3z" fill="currentColor" />
          </svg>
          <span>TRIPBOT</span>
        </Link>
        {children}
        <footer className="site-footer">
          <span>TripBOT · contracts on BOT Chain mainnet · demo runs on testnet</span>
          <span>Centralized demo arbiter · ERC-8004-inspired stand-ins</span>
        </footer>
      </body>
    </html>
  );
}
