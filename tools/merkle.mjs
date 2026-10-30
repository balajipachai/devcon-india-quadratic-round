#!/usr/bin/env node
// Builds the eligibility Merkle tree for one QuadraticFunding deployment.
//
//   node tools/merkle.mjs <members.txt> <contractAddress> <out.json>
//
// members.txt: one 0x address per line (blank lines and # comments ignored).
// The leaf mirrors the contract exactly: keccak256(keccak256(abi.encode(contract, member))),
// with sorted-pair hashing, like OpenZeppelin's MerkleProof. The contract address is in the leaf,
// so a list built for one deployment cannot be replayed on another.
import { readFileSync, writeFileSync } from "node:fs";
import { encodeAbiParameters, getAddress, isAddress, keccak256, concatHex } from "viem";

const [, , membersFile, contract, outFile] = process.argv;
if (!membersFile || !contract || !outFile) {
  console.error("usage: node tools/merkle.mjs <members.txt> <contractAddress> <out.json>");
  process.exit(1);
}
if (!isAddress(contract)) throw new Error(`bad contract address: ${contract}`);

const members = [...new Set(
  readFileSync(membersFile, "utf8").split("\n").map((l) => l.split("#")[0].trim()).filter(Boolean).map((a) => {
    if (!isAddress(a)) throw new Error(`bad member address: ${a}`);
    return getAddress(a);
  }),
)];
if (members.length === 0) throw new Error("no members");

const leaf = (m) => keccak256(keccak256(encodeAbiParameters([{ type: "address" }, { type: "address" }], [contract, m])));
const pair = (a, b) => (a.toLowerCase() < b.toLowerCase() ? keccak256(concatHex([a, b])) : keccak256(concatHex([b, a])));

const leaves = members.map(leaf);
function build(level) {
  const layers = [level];
  while (level.length > 1) {
    const next = [];
    for (let i = 0; i < level.length; i += 2) next.push(i + 1 < level.length ? pair(level[i], level[i + 1]) : level[i]);
    layers.push(next);
    level = next;
  }
  return layers;
}
const layers = build(leaves);
const root = layers.at(-1)[0];

function proofFor(index) {
  const proof = [];
  let idx = index;
  for (const layer of layers.slice(0, -1)) {
    const sib = idx ^ 1;
    if (sib < layer.length) proof.push(layer[sib]);
    idx = Math.floor(idx / 2);
  }
  return proof;
}
function verify(proof, leafHash) {
  return proof.reduce((h, p) => pair(h, p), leafHash) === root;
}

const proofs = {};
members.forEach((m, i) => {
  const p = proofFor(i);
  if (!verify(p, leaves[i])) throw new Error(`self-check failed for ${m}`);
  proofs[m] = p;
});

writeFileSync(outFile, JSON.stringify({ contract: getAddress(contract), root, members: members.length, proofs }, null, 2) + "\n");
console.log(`root ${root}  (${members.length} members, contract ${getAddress(contract)}) -> ${outFile}`);
