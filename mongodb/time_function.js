function time(command) {
    const t1 = new Date();
    const result = command();
    const t2 = new Date();
    print("time: " + (t2 - t1) + "ms");
    return result;
}

pipe = [{
    $match: {
        $expr: {
            $gt: [
                '$date',
                {
                    $subtract: [
                        '$$NOW',
                        300000
                    ]
                }
            ]
        }
    }
}, {
    $sort: {
        date: 1
    }
}, { $limit: 1 }]


time(() => db.XRP.aggregate(pipe))