// GENERADO por docs/src/tools/frame_size.py --export-vectors. No editar a mano.
const kVectorsJson = r'''[
  {
    "name": "sos_min",
    "kind": "report",
    "key": "clave-de-ejemplo",
    "input": {
      "device_id": "9a3c51e07b2d44f1",
      "seq": 17,
      "rev": 0,
      "ref_seq": null,
      "prio_hint": 0,
      "incident_type": 3,
      "flags": 192,
      "people_bucket": 2,
      "loc_quality": 2,
      "lat": 5.0703,
      "lon": -75.5138,
      "captured_at": 1786370851,
      "battery_q": 1,
      "text": null
    },
    "hex": "01609a3c51e07b2d44f100000011000d3c04a1cd829293486d4f3b64622bf36cc5"
  },
  {
    "name": "rev_no_text",
    "kind": "report",
    "key": "clave-de-ejemplo",
    "input": {
      "device_id": "9a3c51e07b2d44f1",
      "seq": 18,
      "rev": 1,
      "ref_seq": 17,
      "prio_hint": 0,
      "incident_type": 3,
      "flags": 192,
      "people_bucket": 2,
      "loc_quality": 2,
      "lat": 5.0703,
      "lon": -75.5138,
      "captured_at": 1786370851,
      "battery_q": 1,
      "text": null
    },
    "hex": "01649a3c51e07b2d44f10000001201000000110d3c04a1cd829293486d4f3b646262d9edf9"
  },
  {
    "name": "rev_with_text",
    "kind": "report",
    "key": "clave-de-ejemplo",
    "input": {
      "device_id": "9a3c51e07b2d44f1",
      "seq": 18,
      "rev": 1,
      "ref_seq": 17,
      "prio_hint": 0,
      "incident_type": 3,
      "flags": 192,
      "people_bucket": 2,
      "loc_quality": 2,
      "lat": 5.0703,
      "lon": -75.5138,
      "captured_at": 1786370851,
      "battery_q": 1,
      "text": "Edificio colapsado en la esquina, hay una persona atrapada bajo la losa y otra herida"
    },
    "hex": "01649a3c51e07b2d44f1000000120100000011633c04a1cd829293486d4f3b646355456469666963696f20636f6c61707361646f20656e206c612065737175696e612c2068617920756e6120706572736f6e612061747261706164612062616a6f206c61206c6f73612079206f74726120686572696461a23cf135"
  },
  {
    "name": "no_location",
    "kind": "report",
    "key": "clave-de-ejemplo",
    "input": {
      "device_id": "9a3c51e07b2d44f1",
      "seq": 20,
      "rev": 0,
      "ref_seq": null,
      "prio_hint": 0,
      "incident_type": 3,
      "flags": 192,
      "people_bucket": 2,
      "loc_quality": 0,
      "lat": null,
      "lon": null,
      "captured_at": 1786370851,
      "battery_q": 1,
      "text": null
    },
    "hex": "01609a3c51e07b2d44f10000001400073c041a9e76c8c4f535e42c"
  },
  {
    "name": "high_bit_device",
    "kind": "report",
    "key": "clave-de-ejemplo",
    "input": {
      "device_id": "ffffffffffffffff",
      "seq": 4294967295,
      "rev": 0,
      "ref_seq": null,
      "prio_hint": 0,
      "incident_type": 3,
      "flags": 192,
      "people_bucket": 2,
      "loc_quality": 2,
      "lat": 5.0703,
      "lon": -75.5138,
      "captured_at": 4294967295,
      "battery_q": 1,
      "text": null
    },
    "hex": "0160ffffffffffffffffffffffff000d3c04a1cd829293487fffffffe2d494e667"
  },
  {
    "name": "text_accents_140",
    "kind": "report",
    "key": "clave-de-ejemplo",
    "input": {
      "device_id": "9a3c51e07b2d44f1",
      "seq": 21,
      "rev": 0,
      "ref_seq": null,
      "prio_hint": 0,
      "incident_type": 3,
      "flags": 192,
      "people_bucket": 2,
      "loc_quality": 2,
      "lat": 5.0703,
      "lon": -75.5138,
      "captured_at": 1786370851,
      "battery_q": 1,
      "text": "áááááááááááááááááááááááááááááááááááááááááááááááááááááááááááááááááááááá"
    },
    "hex": "01609a3c51e07b2d44f100000015009b013c04a1cd829293486d4f3b64638c01c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a1c3a11bffbe8b"
  },
  {
    "name": "ack_basic",
    "kind": "ack",
    "key": "clave-de-ejemplo",
    "input": {
      "device_id": "9a3c51e07b2d44f1",
      "ack_seq": 17,
      "bitmap": 5
    },
    "hex": "02009a3c51e07b2d44f10000001100000005ad10691e"
  }
]''';
