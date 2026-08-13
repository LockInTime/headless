#!/usr/bin/env node

import { launch } from "../lib/launcher.mjs";

await launch("headless-mcp", process.argv.slice(2));
