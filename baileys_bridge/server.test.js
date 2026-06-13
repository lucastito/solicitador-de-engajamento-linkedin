const assert = require('node:assert/strict');
const test = require('node:test');
const {
  normalizePhone,
  toJid,
} = require('./server');

test('normaliza números brasileiros sem código do país', () => {
  assert.equal(normalizePhone('(00) 00000-0000'), '5500000000000');
});

test('preserva números que já possuem o código do país', () => {
  assert.equal(normalizePhone('+55 00 00000-0000'), '5500000000000');
});

test('retorna vazio quando não há número', () => {
  assert.equal(normalizePhone(''), '');
});

test('converte telefone normalizado em JID do WhatsApp', () => {
  assert.equal(toJid('5500000000000'), '5500000000000@s.whatsapp.net');
});
