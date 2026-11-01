# Qwen3-Embedding as RomeoDB's embedder: loaded when Qwen3EmbeddingRunner is.
module RomeoDBQwen3EmbeddingExt

using RomeoDB, Qwen3EmbeddingRunner

RomeoDB.embeddocument(m::Qwen3Embedding, text::AbstractString) = embed(m, text)
RomeoDB.embedquery(m::Qwen3Embedding, text::AbstractString) = embed_query(m, text)

end
