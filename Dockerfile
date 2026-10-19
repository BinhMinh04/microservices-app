# syntax=docker/dockerfile:1
# ... (giữ nguyên khối comment đầu file)

# Image Node dùng chung cho mọi stage. Khai báo bằng ARG TRƯỚC FROM đầu tiên (global ARG)
# để tag + digest chỉ nằm ở MỘT chỗ; stage build và runtime cùng tham chiếu.
ARG NODE_IMAGE=node:24.21.0-trixie-slim@sha256:173f125896c3b47ddf056734c7ea789d04595a6a08769a8f78e0df642781fb66

# ---------- base: chạy theo kiến trúc ĐÍCH (TARGETPLATFORM, mặc định của buildx) ----------
FROM ${NODE_IMAGE} AS base
WORKDIR /app
ENV YARN_CACHE_FOLDER=/tmp/yarn-cache

# ---------- deps: giữ nguyên ----------
FROM base AS deps
# ...

# ---------- build: chạy NATIVE trên máy build (BUILDPLATFORM) ----------
# tsc chỉ sinh JavaScript (không phụ thuộc kiến trúc), nên compile 1 lần, không cần giả lập.
# Build amd64 + arm64 trên Mac M4 thì stage này chạy arm64 native cho cả hai.
FROM --platform=$BUILDPLATFORM ${NODE_IMAGE} AS build
WORKDIR /app
ENV YARN_CACHE_FOLDER=/tmp/yarn-cache
COPY code/package.json code/yarn.lock ./
# ... (giữ nguyên phần còn lại của stage build và toàn bộ runtime)
RUN --mount=type=cache,target=/tmp/yarn-cache,sharing=locked \
    yarn install --frozen-lockfile --non-interactive
# Copy source SAU bước install: chỉ sửa code thì layer node_modules vẫn dùng cache
COPY code/ ./
# tsc compile ra dist/, rồi tsc-alias đổi alias (Models, Utils...) thành đường dẫn tương đối
RUN yarn build

# ---------- runtime: image chạy thật trong cluster ----------
FROM base AS runtime
# tini làm PID 1: chuyển SIGTERM cho node và dọn tiến trình zombie
# (app gọi exec() để chạy sequelize-cli khi migration bật trong app).
RUN apt-get update \
 && apt-get install -y --no-install-recommends tini \
 && rm -rf /var/lib/apt/lists/*

# NODE_ENV=production : mặc định an toàn; manifest có thể đổi (migrate/config.js có key production)
# PATH                : CMD gọi thẳng moleculer-runner, và exec("sequelize-cli ...") tìm thấy lệnh
#                       mà không cần yarn làm trung gian (đây là bẫy ở câu 1, bước 1)
# SERVICEDIR          : moleculer-runner tìm service đã compile ở đây
ENV NODE_ENV=production \
    PATH=/app/node_modules/.bin:$PATH \
    SERVICEDIR=dist/services

# Chỉ copy đúng những gì cần lúc chạy (đáp án câu 3).
# Không --chown: file thuộc root, user chạy app chỉ đọc được, nên app không tự sửa code của chính nó.
COPY --from=deps  /app/node_modules ./node_modules
COPY --from=build /app/dist         ./dist
COPY code/package.json code/.sequelizerc ./
COPY code/migrate ./migrate
COPY code/public  ./public

# Dùng UID dạng số thay vì tên "node": kubelet chỉ verify được runAsNonRoot khi USER là số.
# Viết USER node thì Phần 6 sẽ dính lỗi CreateContainerConfigError.
USER 1000:1000

# Chỉ mang tính tài liệu. Cổng thật do env PORT quyết định (app mặc định 3001).
EXPOSE 3001

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["moleculer-runner", "--config", "dist/moleculer.config.js"]