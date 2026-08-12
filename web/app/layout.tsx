import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "TripBOT — verified settlement for agent work",
  description: "A buyer-first demonstration of escrowed AI-agent commerce on BOT Chain.",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en" data-scroll-behavior="smooth">
      <body>
        <div className="floating-brand" aria-label="TripBOT">
            <span className="brand-mark" aria-hidden="true">T</span>
            <span>TRIPBOT</span>
        </div>
        {children}
        <footer className="site-footer">
          <span>TripBOT · BOT Chain testnet only</span>
          <span>Centralized demo arbiter · ERC-8004-inspired stand-ins</span>
        </footer>
      </body>
    </html>
  );
}
