FROM python:3.12-slim

# fastembed тянет onnxruntime; ffmpeg и компиляторы не нужны.
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir "fastembed==0.7.4" "fastapi==0.115.14" "uvicorn==0.35.0"

COPY app.py /app/app.py

# Модель кэшируется в томе, поэтому второй запуск не скачивает её заново.
ENV HF_HOME=/data/hf \
    EMBEDDINGS_MODEL=BAAI/bge-small-en-v1.5 \
    PYTHONUNBUFFERED=1

WORKDIR /app
EXPOSE 8000

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
