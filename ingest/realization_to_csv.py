"""
goods-realization comes back as an accounting-style XLSX (the `reportFormat=CSV` query param is ignored):
sheet 1 = summary with VAT breakdown, sheets 2-6 = appendices (shipped / delivered / unredeemed / returned / lost),
each with ~10 header rows, a real header row starting with 'Номер заказа', and a trailing 'Итого:' row.

This module turns one report into tidy CSVs: data/raw/goods_realization/<run>/<YYYY-MM>/<appendix>.csv
(one row per order line, header = the report's own column names, plus REPORT_MONTH and APPENDIX).

Usage:
  python ingest/realization_to_csv.py data/raw/goods_realization/2026-09-04/2026-08/report.xlsx
  python ingest/realization_to_csv.py data/raw/goods_realization/2026-09-04/2026-08      # dir with extracted sheetN.xml
"""
from __future__ import annotations

import csv
import pathlib
import re
import sys
import zipfile
import xml.etree.ElementTree as ET

NS = {"m": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
APPENDIX = {2: "shipped", 3: "delivered", 4: "unredeemed", 5: "returned", 6: "lost"}
HEADER_FIRST_CELL = "Номер заказа"


def _rows(xml: bytes, shared: list[str]) -> list[list[str]]:
    out = []
    for row in ET.fromstring(xml).iter(f"{{{NS['m']}}}row"):
        vals = []
        for c in row.findall("m:c", NS):
            v, t = c.find("m:v", NS), c.get("t")
            if t == "s" and v is not None:
                vals.append(shared[int(v.text)])
            elif t == "inlineStr":
                vals.append("".join(x.text or "" for x in c.iter(f"{{{NS['m']}}}t")))
            else:
                vals.append(v.text if v is not None else "")
        out.append(vals)
    return out


def _shared(xml: bytes | None) -> list[str]:
    if not xml:
        return []
    return [(t.text or "") for t in ET.fromstring(xml).iter(f"{{{NS['m']}}}t")]


def load_sheets(src: pathlib.Path) -> dict[int, list[list[str]]]:
    """Return {sheet_no: rows} from an .xlsx file or from a directory of extracted sheetN.xml files."""
    if src.is_file():
        with zipfile.ZipFile(src) as zf:
            names = zf.namelist()
            shared = _shared(zf.read("xl/sharedStrings.xml") if "xl/sharedStrings.xml" in names else None)
            sheets = {}
            for n in names:
                m = re.fullmatch(r"xl/worksheets/sheet(\d+)\.xml", n)
                if m:
                    sheets[int(m.group(1))] = _rows(zf.read(n), shared)
            return sheets
    ss = src / "sharedStrings.xml"
    shared = _shared(ss.read_bytes() if ss.exists() else None)
    return {int(p.stem[5:]): _rows(p.read_bytes(), shared) for p in src.glob("sheet*.xml")}


# Report headers are Russian; RAW tables need ASCII identifiers. Unknown headers fall back to COL_<n>.
COLUMNS = {
    "Номер заказа": "ORDER_ID",
    "Ваш номер заказа": "PARTNER_ORDER_ID",
    "Тип заказа": "ORDER_TYPE",
    "Название товара": "OFFER_NAME",
    "Ваш SKU": "SHOP_SKU",
    "SKU на складе": "WAREHOUSE_SKU",
    "Количество переданных в доставку, шт.": "UNITS_SHIPPED",
    "Доставлено, шт.": "UNITS_DELIVERED",
    "Не выкуплено, шт.": "UNITS_UNREDEEMED",
    "Возвращено, шт.": "UNITS_RETURNED",
    "Утрачено, шт.": "UNITS_LOST",
    "Дата оформления заказа": "ORDER_DATE",
    "Дата передачи товара в доставку": "SHIPPED_DATE",
    "Дата доставки товара": "DELIVERED_DATE",
    "Дата поступления невыкупленного товара": "UNREDEEMED_DATE",
    "Дата поступления возвращённого товара": "RETURNED_DATE",
    "Способ оплаты": "PAYMENT_METHOD",
    "Ставка НДС": "VAT_RATE",
    "Цена c НДС без учёта скидок за шт., ₽": "PRICE_BEFORE_DISCOUNT",
    "Ваша скидка по акции маркетплейса на 1 шт., ₽": "DISCOUNT_MARKETPLACE_PROMO",
    "Ваша скидка по бонусам СберСпасибо (за шт.) на 1 шт., ₽": "DISCOUNT_SBER_SPASIBO",
    "Ваша скидка по баллам Яндекс.Плюса на 1 шт., ₽": "DISCOUNT_YANDEX_PLUS",
    "Цена с НДС с учётом всех скидок за шт., ₽": "PRICE_AFTER_DISCOUNT",
    "Регистрационный номер таможенной декларации или Регистрационный номер партии товара, подлежащего прослеживаемости (РНПТ)": "CUSTOMS_DECLARATION_NO",
    "Дата приёма невыкупа складом или сортировочным центром": "UNREDEEMED_RECEIVED_DATE",
    "Дата приёма возврата складом или сортировочным центром": "RETURN_RECEIVED_DATE",
    "Количество доставленных, шт.": "UNITS_DELIVERED",
    "Стоимость выкупленного товара, ₽": "REDEEMED_AMOUNT",
    "Статус УКД": "UKD_STATUS",
    "Дата УКД": "UKD_DATE",
    "Номер УКД": "UKD_NO",
    "Дата корректировочного счёта-фактуры": "CORRECTION_INVOICE_DATE",
    "Номер корректировочного счёта фактуры": "CORRECTION_INVOICE_NO",
    "Дата автокомпенсации": "AUTO_COMPENSATION_DATE",
    "Сумма автокомпенсации, ₽": "AUTO_COMPENSATION_AMOUNT",
    "Дата приёма заказа складом Маркета или выдачи продавцу с СЦ": "LOST_RECEIVED_DATE",
    "Дата декомпенсации": "DECOMPENSATION_DATE",
    "Сумма декомпенсации, ₽": "DECOMPENSATION_AMOUNT",
    "Наименование организации": "B2B_ORG_NAME",
    "ИНН": "B2B_INN",
    "КПП": "B2B_KPP",
    "Юридический адрес": "B2B_LEGAL_ADDRESS",
    "Статус УПД": "UPD_STATUS",
    "Дата УПД": "UPD_DATE",
    "Номер УПД": "UPD_NO",
    "Дата товарной накладной": "WAYBILL_DATE",
    "Номер товарной накладной": "WAYBILL_NO",
    "Дата счёта-фактуры": "INVOICE_DATE",
    "Номер счёта фактуры": "INVOICE_NO",
}
# totals columns differ per appendix ("всех доставленных штук" / "невыкупленных" / ...): match by prefix
TOTAL_PREFIXES = [
    ("Стоимость всех", "без уч", "TOTAL_BEFORE_DISCOUNT"),
    ("Сумма всех скидок", "", "TOTAL_DISCOUNT"),
    ("Стоимость всех", "с учёт", "TOTAL_AFTER_DISCOUNT"),
    ("Сумма НДС", "", "TOTAL_VAT"),
]


def rename(header: list[str]) -> list[str]:
    out = []
    for n, h in enumerate(header):
        name = COLUMNS.get(h)
        if name is None:
            for start, must, en in TOTAL_PREFIXES:
                if h.startswith(start) and must in h:
                    name = en
                    break
        out.append(name or f"COL_{n}")
    return out


def tidy(rows: list[list[str]]) -> tuple[list[str], list[list[str]]]:
    """Cut the preamble: header = first row whose first cell is 'Номер заказа'; drop 'Итого' and empty rows."""
    for i, r in enumerate(rows):
        if r and r[0].strip() == HEADER_FIRST_CELL:
            header = [re.sub(r"\s+", " ", h).strip() for h in r]
            body = [x + [""] * (len(header) - len(x)) for x in rows[i + 1:]
                    if any(x) and not (x and x[0].strip().startswith("Итого"))]
            return header, [b[:len(header)] for b in body]
    return [], []


def convert(src: pathlib.Path) -> list[pathlib.Path]:
    out_dir = src.parent if src.is_file() else src
    month = out_dir.name                                   # <YYYY-MM>
    written = []
    for no, rows in sorted(load_sheets(src).items()):
        if no not in APPENDIX:
            continue
        header, body = tidy(rows)
        if not header:
            continue
        dest = out_dir / f"{APPENDIX[no]}.csv"
        with dest.open("w", newline="", encoding="utf-8") as fh:
            w = csv.writer(fh)
            w.writerow(["REPORT_MONTH", "APPENDIX"] + rename(header))
            for b in body:
                w.writerow([month, APPENDIX[no]] + b)
        print(f"{dest}: {len(body)} rows", file=sys.stderr)
        written.append(dest)
    return written


if __name__ == "__main__":
    for arg in sys.argv[1:]:
        convert(pathlib.Path(arg))
