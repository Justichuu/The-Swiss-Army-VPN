FROM python:3.12-slim

WORKDIR /book
COPY docs/book /book

# No secrets. No network in the default command.
CMD ["python3", "-c", "from pathlib import Path; print('\\n'.join(sorted(str(p) for p in Path('.').rglob('*.md'))))"]
