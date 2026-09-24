import { describe, expect, it } from "vitest";
import type { NetworkInterfaceInfo } from "node:os";
import { findTailnetAddress, isTailnetIPv4 } from "./tailnetAddress.js";

const v4 = (address: string, internal = false): NetworkInterfaceInfo => ({
  address,
  netmask: "255.255.255.255",
  family: "IPv4",
  mac: "00:00:00:00:00:00",
  internal,
  cidr: `${address}/32`,
});

describe("isTailnetIPv4", () => {
  it("accepts 100.64.0.0/10 only", () => {
    expect(isTailnetIPv4("100.64.0.1")).toBe(true);
    expect(isTailnetIPv4("100.101.102.103")).toBe(true);
    expect(isTailnetIPv4("100.127.255.255")).toBe(true);
    expect(isTailnetIPv4("100.63.255.255")).toBe(false);
    expect(isTailnetIPv4("100.128.0.1")).toBe(false);
    expect(isTailnetIPv4("192.168.1.2")).toBe(false);
    expect(isTailnetIPv4("100.64.0.256")).toBe(false);
    expect(isTailnetIPv4("fd7a:115c:a1e0::1")).toBe(false);
  });
});

describe("findTailnetAddress", () => {
  it("returns undefined when no interface has a tailnet address", () => {
    expect(
      findTailnetAddress({ lo0: [v4("127.0.0.1", true)], en0: [v4("192.168.1.20")] })
    ).toBeUndefined();
  });

  it("prefers a utun interface", () => {
    expect(findTailnetAddress({ en5: [v4("100.70.0.9")], utun4: [v4("100.101.1.2")] })).toEqual({
      address: "100.101.1.2",
      interface: "utun4",
    });
  });

  it("falls back to any non-internal interface in range", () => {
    expect(findTailnetAddress({ en5: [v4("100.70.0.9")], lo0: [v4("100.64.0.1", true)] })).toEqual({
      address: "100.70.0.9",
      interface: "en5",
    });
  });
});
