"use client";

import { useEffect, useState } from "react";

const slides = [
  {
    key: "escrow",
    eyebrow: "01 · BUYER CONTROL",
    title: "ESCROW",
    backdrop: "HOLD",
    copy: "One exact BOT amount enters the job contract. The seller receives nothing before delivery.",
    facts: ["Explicit funding gate", "Price bound to quote", "Seller bond reserved"],
    accent: "cyan",
    symbol: "◇",
  },
  {
    key: "proof",
    eyebrow: "02 · AUTHENTICATED WORK",
    title: "PROOF",
    backdrop: "VERIFY",
    copy: "The paid endpoint checks the buyer signature, the active job, and the one-time delivery claim.",
    facts: ["Signed redemption", "One delivery per job", "Evidence commitment"],
    accent: "violet",
    symbol: "⌁",
  },
  {
    key: "settle",
    eyebrow: "03 · VISIBLE OUTCOME",
    title: "SETTLE",
    backdrop: "RELEASE",
    copy: "Accept pays the seller. A proven bad result refunds the buyer and can slash reserved collateral.",
    facts: ["Receipt-linked release", "Bound dispute evidence", "Neutral timeout exit"],
    accent: "amber",
    symbol: "↗",
  },
] as const;

export function ProtocolCarousel() {
  const [active, setActive] = useState(0);

  useEffect(() => {
    const timer = window.setInterval(() => setActive((value) => (value + 1) % slides.length), 5_500);
    return () => window.clearInterval(timer);
  }, []);

  return (
    <div className="protocol-carousel" aria-label="TripBOT settlement stages">
      <div className="carousel-stage" aria-live="polite">
        {slides.map((slide, index) => {
          const relation = index === active ? "active" : index === (active + 1) % slides.length ? "next" : "previous";
          return (
            <article className={`protocol-slide glass ${relation} ${slide.accent}`} key={slide.key} aria-hidden={index !== active}>
              <span className="slide-backdrop" aria-hidden="true">{slide.backdrop}</span>
              <div className="slide-copy">
                <p>{slide.eyebrow}</p>
                <h3>{slide.title}</h3>
                <span>{slide.copy}</span>
                <ul>{slide.facts.map((fact) => <li key={fact}>{fact}</li>)}</ul>
              </div>
              <div className="slide-glyph" aria-hidden="true"><span>{slide.symbol}</span></div>
            </article>
          );
        })}
      </div>
      <div className="carousel-controls" role="tablist" aria-label="Choose settlement stage">
        {slides.map((slide, index) => (
          <button
            key={slide.key}
            role="tab"
            aria-selected={index === active}
            aria-label={`Show ${slide.title.toLowerCase()} stage`}
            onClick={() => setActive(index)}
          ><span /></button>
        ))}
      </div>
    </div>
  );
}
