import test from "node:test";
import assert from "node:assert/strict";
import { createTradingSafetyGate } from "../dist/trading-safety.js";
const policy = { maxAgeMs: 1000, maxDeviationTicks: 50, referenceTick: 100 };
test("rejects stale, future, diverging oracle or down sequencer on risk-taking trades", () => {
 const gate = createTradingSafetyGate(policy);
 for (const mark of [{tick:100,observedAtMs:0,sequencerUp:true},{tick:200,observedAtMs:1000,sequencerUp:true},
  {tick:100,observedAtMs:1000,sequencerUp:false},{tick:100,observedAtMs:2001,sequencerUp:true}]) {
  assert.throws(() => gate.check("increase-risk",mark,2000));
 }
 gate.check("increase-risk",{tick:110,observedAtMs:1900,sequencerUp:true},2000);
});
test("risk-off halts trades but leaves cancel and settle available", () => {
 const gate=createTradingSafetyGate(policy);gate.halt("incident");
 assert.throws(()=>gate.check("reduce-risk",{tick:100,observedAtMs:1900,sequencerUp:true},2000),/halted/);
 gate.check("cancel",{},2000);gate.check("settle",{},2000);
 gate.resume();gate.check("reduce-risk",{tick:100,observedAtMs:1900,sequencerUp:true},2000);
});
