// Public fixture construction only. No saved Notes payload, device identifier,
// filesystem input, environment value, or private account state is used here.
// This encodes the complete small topotext graph, including character/attribute
// clocks and child indexes; the read-only decoder's minimal test graph is not
// sufficient evidence that NotesShared can edit a document.
import { gunzipSync } from "node:zlib";

export const text =
  "PUBLIC SYNTHETIC WRITER FIXTURE\n" +
  "All contents and identifiers in this note are generated.\n" +
  "This note contains no user data or device identifiers.\n" +
  "For use in isolated fixture validation.\n";
export const replicaIdentifier = "11111111-1111-4111-8111-111111111111";
export const paragraphIdentifier = "22222222-2222-4222-8222-222222222222";
export const noteIdentifier = "33333333-3333-4333-8333-333333333333";

if (text.length !== 184 || Buffer.byteLength(text, "utf8") !== 184) {
  throw new Error("Synthetic text must cover exactly 184 ASCII/UTF-16 units");
}

function varint(value) {
  const bytes = [];
  while (value > 0x7f) {
    bytes.push((value & 0x7f) | 0x80);
    value = Math.floor(value / 128);
  }
  return Buffer.from([...bytes, value]);
}
const concat = (...parts) => Buffer.concat(parts);
const number = (field, value) => concat(varint(field * 8), varint(value));
const bytes = (field, value) => concat(varint(field * 8 + 2), varint(value.length), value);
const uuid = (value) => Buffer.from(value.replaceAll("-", ""), "hex");
const clock = (replica, counter) => concat(number(1, replica), number(2, counter));

/** Return a fresh gzip document built entirely from public fixture constants. */
export function buildSyntheticNotePayload(...inputs) {
  if (inputs.length) throw new TypeError("Synthetic payload construction accepts no input");
  return buildPublicPayload(true);
}

/** Same public nonempty body/topology, with length-only attribute dictionaries. */
export function buildSyntheticAttributeFreePayload(...inputs) {
  if (inputs.length) throw new TypeError("Synthetic payload construction accepts no input");
  return buildPublicPayload(false);
}

// Canonical gzip encodings of the public fields constructed below. zlib releases
// can encode identical input as different valid DEFLATE streams. Pin the bytes
// accepted by the native fixture and verify their complete decoded contents on
// every call; these constants never come from a saved Notes document.
const styledGzip = "H4sIAAAAAAAC/32Qy06DQBSGmV4nsxGINg3eJqwIC17AdEFNGzHGmJbGuiRlaidBMDBtdGd9By/P4BN0pyu3voMvoqdTrC6IZ3P++f5z/mHAiv5ewYqqGK8VfYHOBu0T75D2L079o44P6rzn+Z0e7XpDf9DrEDeK6CiJBYtFRoM4pDwEycecpRnlMRUTntE4EYwGKaOXLGZpIFjoEH9tLNcDHi9PdJqxlIaBCGgCnc34iP1NdEgXOAwto3mWRMssOuY3YgrpsyDisMuT2CGGSuQr4B2yW0gSBKRlyG6VctJSh5Igq2xopArqEQ75UCVHTz+oZFVz9IxUmk/VcvTwO1U3GgTDzV9QG/AVa23ukm2iarJcbb4Sml7GC6SXcNk+wC19s4mOVVNW27xfCdPYJw3Hvb6OWP82E+xq4HXhz7WTKNxSlDe3iSxkN/GweNnew6jYmdx9frzU7B1c1/V/XKPQnUu3AdkF7jccmDzzSwIAAA==";
const attributeFreeGzip = "H4sIAAAAAAAC/02Pz0rEMBDGm3bXDbnY9uAhIgyeioe+QQ+rdLEgIrWL9Ri2WQ2UFNrs4tW7N/HPo+zb6aTG1YFhvvnlm0lCvfg1oF7o8Zcg3pGb5flVcQG399fVZV6huiuLKi9hUdTVsszZvG1h1WkjtRlA6AZUg1KtlewHUBrMoxpAd0aC6CU8SC17YWSTsmp/YMeF0raDzSB7aIQR0GGVW7WS/zembIEcTXa1GrrW7oK1ejIb3L4VrcJZ1emU8ZBN7C/wH2NNyEgIkoyPNfEdycJ6JCQJeMSmqN6xcaaJQx+/yE+mDn2SEJzrwKG3P9eMHzGKN39hHOIr9vr0hB2zMBpjHj3/iCgO6I7EPg3OfJph1pgEc4bJrf4Goxi7KJgBAAA=";

function buildPublicPayload(styled) {
  // owner, character counter, length, attribute owner/counter, child index.
  // Replica zero at the two boundaries is structural, not a clock-table owner.
  const topology = [
    [0, 0, 0, 0, 0, 1],
    [1, 0, 61, 1, 0, 2],
    [1, 61, 88, 1, 1, 3],
    [1, 150, 1, 1, 0, 4],
    [1, 151, 1, 1, 2, 5],
    [1, 152, 32, 1, 0, 6],
    [1, 149, 1, 1, 2, 7],
    [0, 0xffffffff, 0, 0, 0xffffffff, null],
  ];
  const substrings = topology.map(([owner, counter, length, attrOwner, attrCounter, child]) =>
    bytes(
      3,
      concat(
        bytes(1, clock(owner, counter)),
        number(2, length),
        bytes(3, clock(attrOwner, attrCounter)),
        child === null ? Buffer.alloc(0) : number(5, child)
      )
    )
  );
  const timestamp = bytes(
    4,
    bytes(
      1,
      concat(bytes(1, uuid(replicaIdentifier)), bytes(2, number(1, 184)), bytes(2, number(1, 3)))
    )
  );
  const pointSize = Buffer.alloc(4);
  pointSize.writeFloatLE(24);
  const font = concat(
    bytes(1, Buffer.from(".AppleSystemUIFontBold", "utf8")),
    varint(2 * 8 + 5),
    pointSize,
    number(3, 1)
  );
  const attributeRuns = [61, 88, 1, 7, 26, 1].map((length, index) => {
    if (!styled) return bytes(5, number(1, length));
    const style = concat(
      index < 3 ? number(3, 1) : Buffer.alloc(0),
      bytes(9, uuid(paragraphIdentifier))
    );
    return bytes(
      5,
      concat(
        number(1, length),
        bytes(2, style),
        index === 0 ? concat(bytes(3, font), number(5, 1)) : Buffer.alloc(0),
        // Fixed fixture timestamps preserve ordering without recording a run's
        // wall-clock time. They are not taken from a Notes snapshot.
        index >= 2 && index <= 4
          ? number(13, index === 4 ? 1700000001 : 1700000000)
          : Buffer.alloc(0)
      )
    );
  });
  const string = concat(
    bytes(2, Buffer.from(text, "utf8")),
    ...substrings,
    timestamp,
    ...attributeRuns
  );
  const version = concat(number(1, 0), number(2, 0), bytes(3, string));
  const publicDocument = concat(number(1, 0), bytes(2, version));
  const compressed = Buffer.from(styled ? styledGzip : attributeFreeGzip, "base64");
  if (!gunzipSync(compressed).equals(publicDocument)) {
    throw new Error("Canonical fixture encoding does not match the generated public fields");
  }
  return compressed;
}
