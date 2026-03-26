/*
  validate_with_formats.js
  Usage: node validate_with_formats.js <schema.json> <data.json>
*/
const fs = require('fs');
const Ajv = require('ajv');
const addFormats = require('ajv-formats');

if (process.argv.length < 4) {
  console.error('Usage: node validate_with_formats.js <schema.json> <data.json>');
  process.exit(2);
}

const schemaFile = process.argv[2];
const dataFile = process.argv[3];

try {
  const schema = JSON.parse(fs.readFileSync(schemaFile, 'utf8'));
  const data = JSON.parse(fs.readFileSync(dataFile, 'utf8'));

  const ajv = new Ajv({ allErrors: true, strict: false });
  addFormats(ajv);

  const validate = ajv.compile(schema);
  const valid = validate(data);

  if (!valid) {
    console.error('AJV validation failed:');
    console.error(JSON.stringify(validate.errors, null, 2));
    process.exit(1);
  }
  console.log('AJV validation OK');
  process.exit(0);
} catch (err) {
  console.error('Validator error:', err && err.message ? err.message : err);
  process.exit(1);
}
