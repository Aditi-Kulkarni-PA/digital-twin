from pypdf import PdfReader
import json
from pathlib import Path


DATA_DIR = Path(__file__).resolve().parent / "data"

# Read LinkedIn PDF
try:
    reader = PdfReader(str(DATA_DIR / "linkedin.pdf"))
    linkedin = ""
    for page in reader.pages:
        text = page.extract_text()
        if text:
            linkedin += text
except FileNotFoundError:
    linkedin = "LinkedIn profile not available"

# Read other data files
with open(DATA_DIR / "summary.txt", "r", encoding="utf-8") as f:
    summary = f.read()

with open(DATA_DIR / "style.txt", "r", encoding="utf-8") as f:
    style = f.read()

with open(DATA_DIR / "facts.json", "r", encoding="utf-8") as f:
    facts = json.load(f)

with open(DATA_DIR / "resume.html", "r", encoding="utf-8") as f:
    resume = f.read()