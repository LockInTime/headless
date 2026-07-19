import type { Metadata } from "next";
import "./globals.css";
import { Instrument_Sans, JetBrains_Mono, Source_Sans_3 } from "next/font/google";
import { cn } from "@/lib/utils";

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

export const metadata: Metadata = {
  title: "Headless — browser control for agents",
  description: "Persistent, secure browser control for AI agents. No screen coordinates. No browser scripts.",
};

const setInitialTheme = `(function(){try{var s=localStorage.getItem("theme");var t=s==="light"||s==="dark"?s:(matchMedia("(prefers-color-scheme: light)").matches?"light":"dark");document.documentElement.setAttribute("data-theme",t);}catch(e){}})();`;

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html
      lang="en"
      className={cn(instrumentSans.variable, sourceSans.variable, jetbrainsMono.variable)}
      suppressHydrationWarning
    >
      <body>
        <script dangerouslySetInnerHTML={{ __html: setInitialTheme }} />
        {children}
      </body>
    </html>
  );
}
