FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt /app/requirements.txt
RUN python -m pip install --no-cache-dir --require-hashes -r requirements.txt
COPY engine.py server.py COPYING /app/
USER 1000:1000
EXPOSE 8443
ENTRYPOINT ["python", "-B", "/app/server.py"]
