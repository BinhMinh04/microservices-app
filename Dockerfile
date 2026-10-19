# syntax=docker/dockerfile:1
# =====================================================================
# Image chung cho Moleculer microservice: api-gateway / categories / news.
# Chọn service lúc chạy bằng env SERVICES (api | categories | news).
# Build context: gốc repo (code nằm trong code/).
# Multi-arch: docker buildx build --platform linux/amd64,linux/arm64 ...
# =====================================================================

# Image Node dùng chung cho mọi stage. Khai báo bằng ARG TRƯỚC FROM đầu tiên (global ARG)
# để tag + digest chỉ nằm ở MỘT chỗ.
# Pin tag (để người đọc hiểu) + digest của INDEX multi-arch (để build lặp lại được).
# Vì là digest của index nên buildx vẫn tự chọn đúng amd64/arm64.
# Nâng version = đổi cả tag lẫn digest (Phần 8 để bot mở PR).
ARG NODE_IMAGE=node:24.21.0-trixie-slim@sha256:173f125896c3b47ddf056734c7ea789d04595a6a08769a8f78e0df642781fb66

# ---------- base: chạy theo kiến trúc ĐÍCH (TARGETPLATFORM) ----------
FROM ${NODE_IMAGE} AS base
WORKDIR /app
# Thư mục cache của yarn đặt cố định để dùng chung với cache mount ở dưới
ENV YARN_CACHE_FOLDER=/tmp/yarn-cache

# ---------- deps: chỉ production dependencies, theo kiến trúc ĐÍCH ----------
# Giữ ở TARGETPLATFORM: nếu sau này có native module, node_modules phải khớp kiến trúc chạy.
FROM base AS deps
COPY code/package.json code/yarn.lock ./
# --frozen-lockfile : lockfile lệch package.json thì FAIL thay vì âm thầm cập nhật
# --production      : bỏ devDependencies (typescript, jest, eslint, ts-node...)
# cache mount       : package tải về được giữ giữa các lần build, nhưng KHÔNG nằm trong layer
# sharing=locked    : các stage chạy song song dùng chung cache này; yarn v1 không chịu được
#                     2 tiến trình ghi cache cùng lúc → khoá để chạy lần lượt
RUN --mount=type=cache,target=/tmp/yarn-cache,sharing=locked \
    yarn install --frozen-lockfile --production --non-interactive

# ---------- build: chạy NATIVE trên máy build (BUILDPLATFORM) ----------
# tsc chỉ sinh JavaScript (không phụ thuộc kiến trúc) → compile 1 lần, không cần giả lập.
# --platform phải áp lên image thật, nên không dùng "FROM base" mà khai báo lại WORKDIR/ENV.
FROM --platform=$BUILDPLATFORM ${NODE_IMAGE} AS build
WORKDIR /app
ENV YARN_CACHE_FOLDER=/tmp/yarn-cache
COPY code/package.json code/yarn.lock ./
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
#                       mà không cần yarn làm trung gian
# SERVICEDIR          : moleculer-runner tìm service đã compile ở đây
ENV NODE_ENV=production \
    PATH=/app/node_modules/.bin:$PATH \
    SERVICEDIR=dist/services

# Chỉ copy đúng những gì cần lúc chạy.
# Không --chown: file thuộc root, user chạy app chỉ đọc được → app không tự sửa code của chính nó.
COPY --from=deps  /app/node_modules ./node_modules
COPY --from=build /app/dist         ./dist
COPY code/package.json code/.sequelizerc ./
COPY code/migrate ./migrate
COPY code/public  ./public

# UID dạng số thay vì tên "node": kubelet chỉ verify được runAsNonRoot khi USER là số.
USER 1000:1000

# Chỉ mang tính tài liệu. Cổng thật do env PORT quyết định (app mặc định 3001).
EXPOSE 3001

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["moleculer-runner", "--config", "dist/moleculer.config.js"]
