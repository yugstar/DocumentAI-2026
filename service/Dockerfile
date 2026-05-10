FROM python:3.13-slim-bookworm

WORKDIR /app

ENV PORT=8080
EXPOSE 8080

COPY requirements.txt /app/requirements.txt
RUN pip3 install --no-cache-dir -r requirements.txt

COPY . /app

# Cloud Run injects PORT at runtime; JSON CMD does not expand vars — use sh -c.
CMD ["/bin/sh", "-c", "exec gunicorn --bind 0.0.0.0:${PORT:-8080} --workers 1 --threads 8 --timeout 0 api:app"]
