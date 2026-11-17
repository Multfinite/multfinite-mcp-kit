"""OpenAI-compatible /v1/embeddings backed by fastembed.

Graphiti and Cognee both call the OpenAI embeddings API, but Graphiti has no
fastembed provider of its own. This service gives them one endpoint without an
Ollama runtime: the model is loaded once at startup and kept in HF_HOME, so a
container restart does not download it again.
"""
import os
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastembed import TextEmbedding
from pydantic import BaseModel

MODEL_NAME = os.environ.get("EMBEDDINGS_MODEL", "BAAI/bge-small-en-v1.5")

state: dict[str, object] = {}


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Первый старт скачивает модель в HF_HOME (том), дальше берётся из кэша.
    state["model"] = TextEmbedding(model_name=MODEL_NAME)
    yield
    state.clear()


app = FastAPI(lifespan=lifespan)


class EmbeddingsRequest(BaseModel):
    input: str | list[str]
    model: str | None = None
    encoding_format: str | None = None


@app.get("/healthz")
def healthz():
    return {"status": "ok", "model": MODEL_NAME, "ready": "model" in state}


@app.get("/v1/models")
def models():
    return {"object": "list", "data": [{"id": MODEL_NAME, "object": "model", "owned_by": "fastembed"}]}


@app.post("/v1/embeddings")
def embeddings(request: EmbeddingsRequest):
    model = state["model"]
    texts = [request.input] if isinstance(request.input, str) else list(request.input)
    vectors = [vector.tolist() for vector in model.embed(texts)]
    return {
        "object": "list",
        "model": MODEL_NAME,
        "data": [
            {"object": "embedding", "index": index, "embedding": vector}
            for index, vector in enumerate(vectors)
        ],
        "usage": {"prompt_tokens": 0, "total_tokens": 0},
    }
