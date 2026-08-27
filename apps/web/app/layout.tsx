import type { Metadata } from "next";
import "./globals.css";
import {
  Instrument_Sans,
  JetBrains_Mono,
  Source_Sans_3,
} from "next/font/google";
import { cn } from "@/lib/utils";
import { SITE_URL } from "@/lib/site-metadata";

const instrumentSans = Instrument_Sans({
  subsets: ["latin"],
  weight: ["400", "500", "600", "700"],
  variable: "--font-display",
});
const sourceSans = Source_Sans_3({
  subsets: ["latin"],
  weight: ["400", "500", "600", "700"],
  variable: "--font-body",
});
const jetbrainsMono = JetBrains_Mono({
  subsets: ["latin"],
  weight: ["400", "500", "600", "700"],
  variable: "--font-mono",
});

const description =
  "Persistent, secure browser control for AI agents. No screen coordinates. No browser scripts.";

// icon.svg, apple-icon.tsx, and opengraph-image.tsx are picked up by the App
// Router file conventions, so icons are not declared by hand here. The bare
// mark in public/ stays where it is — the nav brand uses it as a CSS mask and
// takes its colour from currentColor.
export const metadata: Metadata = {
  metadataBase: new URL(SITE_URL),
  title: "Headless — browser control for agents",
  description,
  openGraph: {
    title: "Headless — browser control for agents",
    description,
    siteName: "Headless",
    type: "website",
  },
  twitter: {
    card: "summary_large_image",
    title: "Headless — browser control for agents",
    description,
  },
};

const setInitialTheme = `(function(){try{var s=localStorage.getItem("theme");var t=s==="light"||s==="dark"?s:(matchMedia("(prefers-color-scheme: light)").matches?"light":"dark");document.documentElement.setAttribute("data-theme",t);}catch(e){}})();`;

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html
      lang="en"
      className={cn(
        instrumentSans.variable,
        sourceSans.variable,
        jetbrainsMono.variable,
      )}
      suppressHydrationWarning
    >
      <body>
        <script dangerouslySetInnerHTML={{ __html: setInitialTheme }} />
        {children}
      </body>
    </html>
  );
}
