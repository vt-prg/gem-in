FROM python:3.11-slim

WORKDIR /app

COPY gem_latest.py /app/gem_latest.py
RUN pip install --no-cache-dir requests boto3

RUN mkdir -p /data/pdfs

CMD sh -c 'python /app/gem_latest.py --keyword "Toner" --state "Uttar Pradesh" --pages 5 --out /data/latest_bids.json --download-pdf --pdf-dir /data/pdfs --pdf-timeout 90 --upload-s3 --s3-bucket svt-gem-dw-1 --s3-prefix gemdw'
