#!/usr/bin/env node
/*
 * Thin native-solc shim over solc-js so Foundry can compile in this sandbox,
 * where the solc binary hosts (binaries.soliditylang.org, github releases) are
 * blocked by the egress proxy but npm is reachable.
 *
 * Emulates the two invocations Foundry uses:
 *   solc --version         → prints a "Version: x.y.z+commit...." line
 *   solc --standard-json    → reads Standard-JSON from stdin, writes it to stdout
 */
const fs = require("fs");
const solc = require("solc");

// Synchronous, complete write to a file descriptor (process.stdout.write can be
// truncated when a large payload is still buffered at process.exit).
function writeAll(fd, str) {
  const buf = Buffer.from(str, "utf8");
  let off = 0;
  while (off < buf.length) {
    off += fs.writeSync(fd, buf, off, buf.length - off);
  }
}

const args = process.argv.slice(2);

if (args.includes("--version")) {
  writeAll(
    1,
    "solc, the solidity compiler commandline interface\n" +
      "Version: " +
      solc.version() +
      "\n"
  );
  process.exit(0);
}

if (args.includes("--standard-json")) {
  const input = fs.readFileSync(0, "utf8");
  const output = solc.compile(input);
  writeAll(1, output);
  process.exit(0);
}

writeAll(2, "solc-wrapper: unsupported args: " + args.join(" ") + "\n");
process.exit(1);
