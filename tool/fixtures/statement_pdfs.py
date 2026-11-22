"""Writes the synthetic statement PDFs in test/fixtures.

Every name, number and receipt is made up; never put real data here.

The M-Pesa layout follows the public M-Pesa statement table: fixed columns,
details wrapped inside their column, amounts right-aligned, withdrawals
printed negative, newest row first, and the header repeated on every page.

The KCB layout follows KCB's transactional account statement: the account
header and overview on every page, cells centred in their rows (so wrapped
text sits above and below the date), money out printed negative, rows cut
by page breaks, the statement date and period overlaid on the table in
large type, a footer on every page and a closing summary page.

    pip install reportlab==5.0.1 pypdf==6.17.0
    python3 tool/fixtures/statement_pdfs.py

Writes synthetic_statement.pdf and synthetic_statement_locked.pdf (AES-128,
password 0000), and synthetic_kcb_statement.pdf and
synthetic_kcb_statement_locked.pdf (AES-128, password 5678: the 5th to the
8th digits of the made-up account number 1234567890).
"""

from pathlib import Path

from pypdf import PdfReader, PdfWriter
from reportlab.lib.pagesizes import A4
from reportlab.pdfgen import canvas

OUT = Path(__file__).resolve().parents[2] / "test" / "fixtures"
FONT, SIZE, LEADING = "Helvetica", 8, 11
PAGE_W, PAGE_H = A4

# (receipt, completion time, details, paid in, withdrawn, balance), newest first.
ROWS = [
    ("TJA0000004", "2026-10-26 13:45:00",
     "Merchant Payment Online to 5000001 - EXAMPLE GROCERS", "", "-350.00", "5,135.00"),
    ("TJA0000001", "2026-10-26 09:15:42",
     "Customer Transfer of Funds Charge", "", "-15.00", "5,485.00"),
    ("TJA0000001", "2026-10-26 09:15:42",
     "Customer Transfer to - 0700***001 JANE DOE", "", "-1,500.00", "5,500.00"),
    ("TJA0000003", "2026-10-26 08:02:10",
     "Funds received from - 0700***002 JOHN KAMAU", "2,000.00", "", "7,000.00"),
]

# Left edges of text columns, right edges of amount columns.
COLS = {
    "receipt": 30, "time": 82, "details": 165, "status": 330,
    "paid_in": 440, "withdrawn": 500, "balance": 565,
}
HEADERS = [
    ("Receipt No.", "receipt", False), ("Completion Time", "time", False),
    ("Details", "details", False), ("Transaction Status", "status", False),
    ("Paid In", "paid_in", True), ("Withdrawn", "withdrawn", True),
    ("Balance", "balance", True),
]
DETAILS_WIDTH = 155


def wrap(c, text):
    lines, line = [], ""
    for word in text.split():
        trial = f"{line} {word}".strip()
        if line and c.stringWidth(trial, FONT, SIZE) > DETAILS_WIDTH:
            lines.append(line)
            line = word
        else:
            line = trial
    return lines + [line]


def draw(c, x, y, text, right=False):
    if right:
        c.drawRightString(x, y, text)
    else:
        c.drawString(x, y, text)


def header(c, y):
    for title, key, right in HEADERS:
        draw(c, COLS[key], y, title, right)
    c.line(28, y - 3, 567, y - 3)
    return y - LEADING - 2


def build(path, lines_on_first_page):
    c = canvas.Canvas(str(path), pagesize=A4, invariant=1)
    c.setFont(FONT, SIZE)
    y = PAGE_H - 40
    for text in ("M-PESA STATEMENT", "Customer Name: JOHN DOE",
                 "Statement Period: 01 Oct 2026 - 31 Oct 2026"):
        draw(c, 30, y, text)
        y -= LEADING
    y = header(c, y - 6)

    table = []
    for receipt, time, details, paid_in, withdrawn, balance in ROWS:
        chunks = wrap(c, details)
        table.append({"receipt": receipt, "time": time, "details": chunks[0],
                      "status": "Completed", "paid_in": paid_in,
                      "withdrawn": withdrawn, "balance": balance})
        table += [{"details": more} for more in chunks[1:]]

    page = 1
    for index, line in enumerate(table):
        if index == lines_on_first_page:
            draw(c, 30, 40, "Page 1 of 2")
            c.showPage()
            c.setFont(FONT, SIZE)
            page = 2
            y = header(c, PAGE_H - 40)
        for _, key, right in HEADERS:
            if line.get(key):
                draw(c, COLS[key], y, line[key], right)
        y -= LEADING
    draw(c, 30, 54, "Disclaimer: synthetic test statement, not a real record.")
    draw(c, 30, 40, f"Page {page} of 2")
    c.save()


KCB_ACCOUNT = "1234567890"
KCB_OPENING = 5000000  # minor units
# Lines within a cell are KCB_LEADING apart, and cells are centred on the
# date, so cells with an even and an odd number of lines interleave half a
# leading apart. KCB_GAP parts the last line of a row from the next row.
KCB_SIZE, KCB_LEADING, KCB_GAP = 5, 8.4, 15.6

# (date, reference, signed amount in minor units, type, details), oldest
# first. A charge shares its transaction's reference. 254700000001 is the
# made-up M-Pesa number of the account holder, JANE DOE.
KCB_ROWS = [
    ("01/Sep/2026", "FT26244AAA01", 2000000, "Direct Credits",
     "Received from KES INWARD CLEARING ACCOUNT bank purpose EXAMPLE EMPLOYER LTD"),
    ("01/Sep/2026", "FT26244AAA01", -5000, "EFT Charge", "EFT Charge"),
    ("01/Sep/2026", "FT26244AAA02", -150000, "Mobile Money Transfer",
     "254700000009-JOHN DOE Mobile Money"),
    ("01/Sep/2026", "FT26244AAA02", -3000, "Transfer Charge",
     "254700000009-JOHN DOE Mobile Money"),
    ("02/Sep/2026", "FT26245AAA03", -500000, "Pesalink Outgoing",
     "JOHN DOE 0123456789-EXAMPLE BANK"),
    ("02/Sep/2026", "FT26245AAA03", -4500, "Pesalink Charge", "Pesalink Charge"),
    ("02/Sep/2026", "FT26245AAA04", 300000, "Vooma Loan Disbursement", "MobileLoan"),
    ("03/Sep/2026", "FT26246AAA05", -85000, "POS Txn", "4000000000000000 EXAMPLE SUPERMARKET"),
    ("03/Sep/2026", "FT26246AAA06", -200000, "Transfer", "Goal Top Up JANE DOE"),
    ("03/Sep/2026", "FT26246AAA06", -1000, "Transfer Charge", "Goal Top Up"),
    ("04/Sep/2026", "FT26247AAA07", -250000, "Mobile Money Transfer",
     "254700000001-JANE DOE Mobile Money"),
    ("04/Sep/2026", "FT26247AAA07", -3000, "Transfer Charge",
     "254700000001-JANE DOE Mobile Money"),
    ("04/Sep/2026", "FT26247AAA08", -310000, "Vooma Loan Interest Loan Recovery", "MobileLoan"),
    ("05/Sep/2026", "FT26248AAA09", -70000, "Mobile Money Transfer",
     "254711111111-JOHN DOE Mobile Money"),
    ("05/Sep/2026", "FT26248AAA10", -10000, "ATM Card Fee", "Pay card fee"),
]

# Text columns (centre of each cell) and amount columns (right edge),
# as KCB prints them on A4.
KCB_HEADERS = [
    ("TXN Date", 21, "left"), ("Value Date", 76, "left"),
    ("Transaction Type", 128, "left"), ("Transaction Details", 211, "left"),
    ("Reference", 314, "left"), ("Money Out", 384, "left"),
    ("Money In", 459, "left"), ("Running Balance", 517, "left"),
]
KCB_CELLS = {"date": (21, "left"), "value": (78, "left"), "kind": (162, "centre"),
             "details": (250, "centre"), "ref": (333, "centre"),
             "out": (420, "right"), "in": (492, "right"), "balance": (563, "right")}
KCB_WIDTHS = {"kind": 45, "details": 92}


def kcb_money(minor):
    sign = "-" if minor < 0 else ""
    return f"{sign}{abs(minor) / 100:,.2f}"


def kcb_wrap(c, text, width):
    lines, line = [], ""
    for word in text.split():
        trial = f"{line} {word}".strip()
        if line and c.stringWidth(trial, FONT, KCB_SIZE) > width:
            lines.append(line)
            line = word
        else:
            line = trial
    return lines + [line]


def kcb_page_header(c, closing):
    """The account header and overview KCB repeats on every page."""
    c.setFont(FONT, 6)
    for i, text in enumerate(["Statement Date", "07/Oct/2026", "Statement Period",
                              "2026-09-01 -", "2026-09-30"]):
        c.drawString(533, PAGE_H - 34 - i * 5, text)
    c.setFont(FONT, 9)
    c.drawString(12, PAGE_H - 72, "Transactional Account PAYG Statement")
    c.setFont(FONT, 6)
    c.drawString(508, PAGE_H - 95, "Branch: KCB EXAMPLE")
    c.drawString(28, PAGE_H - 118, "Account Details")
    c.drawString(320, PAGE_H - 118, "Statement Overview")
    c.drawString(29, PAGE_H - 137, "Customer Name: JANE DOE")
    c.drawString(29, PAGE_H - 154, f"Account Number: {KCB_ACCOUNT}")
    c.drawString(29, PAGE_H - 170, "Customer Address: P.O. BOX 00000 NAIROBI")
    c.drawString(321, PAGE_H - 170, f"Balance at Period Start: KES {kcb_money(KCB_OPENING)}")
    c.drawString(321, PAGE_H - 186, f"Balance at Period End: KES {kcb_money(closing)}")


def kcb_overlay(c):
    """The statement date and period KCB overlays on the table in large type."""
    c.setFont(FONT, 22)
    c.setFillGray(0.85)
    c.drawString(216, PAGE_H - 340, "Statement Date 07/Oct/2026")
    c.drawString(165, PAGE_H - 470, "2026-09-01 - 2026-09-30")
    c.setFillGray(0)


def kcb_footer(c, page, pages):
    c.setFont(FONT, 6)
    c.drawString(495, PAGE_H - 682, f"Showing page {page} of {pages}")
    c.drawString(12, PAGE_H - 740, "KCB synthetic statement. This is test data, not a real record.")


def kcb_table_header(c):
    c.setFont("Helvetica-Bold", 5.5)
    for title, x, _ in KCB_HEADERS:
        c.drawString(x, PAGE_H - 256, title)
    return PAGE_H - 271


def kcb_draw(c, key, y, text):
    x, align = KCB_CELLS[key]
    if align == "centre":
        c.drawCentredString(x, y, text)
    elif align == "right":
        c.drawRightString(x, y, text)
    else:
        c.drawString(x, y, text)


def build_kcb(path, breaks):
    """Lays KCB_ROWS out; each entry of breaks is (row index, lines of that
    row printed before the page break)."""
    c = canvas.Canvas(str(path), pagesize=A4, invariant=1)
    balances, balance = [], KCB_OPENING
    for row in KCB_ROWS:
        balance += row[2]
        balances.append(balance)
    closing = balance
    pages = len(breaks) + 2  # one more for the closing summary

    def start_page():
        kcb_page_header(c, closing)
        kcb_overlay(c)
        return kcb_table_header(c)

    page = 1
    y = start_page()
    c.setFont(FONT, KCB_SIZE)
    c.drawCentredString(250, y, "BALANCE FWD")
    c.drawRightString(563, y, kcb_money(KCB_OPENING))
    y -= KCB_GAP
    cut = dict(breaks)
    for index, (date, ref, amount, kind, details) in enumerate(KCB_ROWS):
        # Offsets from the date's line, in leadings: line i of a cell of n
        # lines sits at i - (n - 1) / 2.
        lines = {0.0: dict(date=date, value=date, ref=ref, balance=kcb_money(balances[index]))}
        lines[0.0]["out" if amount < 0 else "in"] = kcb_money(amount)
        for key, cell in (("kind", kcb_wrap(c, kind, KCB_WIDTHS["kind"])),
                          ("details", kcb_wrap(c, details, KCB_WIDTHS["details"]))):
            for i, text in enumerate(cell):
                lines.setdefault(i - (len(cell) - 1) / 2, {})[key] = text
        offsets = sorted(lines)
        y -= -offsets[0] * KCB_LEADING  # down to the row's first line
        previous = offsets[0]
        for number, offset in enumerate(offsets):
            y -= (offset - previous) * KCB_LEADING
            previous = offset
            if cut.get(index) == number:
                kcb_footer(c, page, pages)
                c.showPage()
                page += 1
                y = start_page()
            c.setFont(FONT, KCB_SIZE)
            for key, text in lines[offset].items():
                kcb_draw(c, key, y, text)
        y -= KCB_GAP
    kcb_footer(c, page, pages)
    c.showPage()
    # The closing summary page: no table header.
    kcb_page_header(c, closing)
    c.setFont(FONT, 6)
    c.drawString(253, PAGE_H - 256, "Balance at Period End")
    c.drawRightString(420, PAGE_H - 256, kcb_money(sum(r[2] for r in KCB_ROWS if r[2] < 0)))
    c.drawRightString(563, PAGE_H - 256, kcb_money(closing))
    c.drawString(27, PAGE_H - 335, "Number of Debits 12")
    kcb_footer(c, pages, pages)
    c.save()


def encrypt(plain, locked, password):
    writer = PdfWriter(clone_from=PdfReader(plain))
    writer.encrypt(user_password=password, owner_password=None, algorithm="AES-128")
    with open(locked, "wb") as f:
        writer.write(f)


def main():
    kcb = OUT / "synthetic_kcb_statement.pdf"
    # Break inside the Pesalink row after its first line (its date is on
    # the next page), and inside the last M-Pesa send after its middle
    # line (its last line opens the third page).
    build_kcb(kcb, breaks=[(4, 1), (13, 2)])
    encrypt(kcb, OUT / "synthetic_kcb_statement_locked.pdf", KCB_ACCOUNT[4:8])

    plain = OUT / "synthetic_statement.pdf"
    # Break after the first row's first line, so its wrapped details
    # continue under the repeated header on page 2.
    build(plain, lines_on_first_page=1)
    writer = PdfWriter(clone_from=PdfReader(plain))
    writer.encrypt(user_password="0000", owner_password=None, algorithm="AES-128")
    with open(OUT / "synthetic_statement_locked.pdf", "wb") as f:
        writer.write(f)


if __name__ == "__main__":
    main()
