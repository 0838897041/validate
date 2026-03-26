import json
import pytest
from jsonschema import validate, ValidationError

@pytest.mark.parametrize("schema_file", ["ai_output_schema.json"])
def test_output_json_conforms(schema_file):
    schema = json.load(open(schema_file))
    data = json.load(open("output.json"))
    try:
        validate(instance=data, schema=schema)
    except ValidationError as e:
        pytest.fail(f"Schema validation failed: {e}")
